/*
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
 * except in compliance with the License. You may obtain a copy of the License at
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software distributed under
 * the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR REPRESENTATIONS
 * OF ANY KIND, either express or implied. See the License for the specific language
 * governing permissions and limitations under the License.
 */

// Charter §8 strict state exporter. Opens one validator's segment store read-only over HTTP
// exactly as a federation mount does (HttpPersistence + ReadOnlyFileStore), pins the head to
// the journal revision it read, and emits a recursive canonical typed export plus SHA-256
// digests as one JSON object on stdout.
//
//   java -cp <oak-segment-consensus.jar> tools/state-exporter/StateExporter.java \
//       --url http://127.0.0.1:8490 --path / [--path /x ...] [--max-nodes N] [--skip-hidden]
//
// Exit codes: 0 export written; 1 usage; 2 traversal/open failure (UNKNOWN, never a partial
// export); 3 --max-nodes exceeded. Every error is still one JSON object on stdout.
//
// Binaries: the read-only store has no BlobStore, so external blob bytes are never fetched.
// Segment-stored binaries are streamed and hashed. External blobs (blob id present) cannot
// yield reference, length or bytes without a BlobStore (SegmentBlob throws
// IllegalStateException "... without specifying BlobStore"); that structurally expected case
// is recorded per value as "unreadable" and listed in the top-level "unreadableBinaries".
// Any other exception is a traversal failure.

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.stream.Stream;

import org.apache.jackrabbit.oak.api.Blob;
import org.apache.jackrabbit.oak.api.PropertyState;
import org.apache.jackrabbit.oak.api.Type;
import org.apache.jackrabbit.oak.segment.SegmentNodeStoreBuilders;
import org.apache.jackrabbit.oak.segment.consensus.mount.MountReadFailures;
import org.apache.jackrabbit.oak.segment.consensus.mount.http.HttpPersistence;
import org.apache.jackrabbit.oak.segment.file.JournalReader;
import org.apache.jackrabbit.oak.segment.file.ReadOnlyFileStore;
import org.apache.jackrabbit.oak.spi.state.NodeState;
import org.apache.jackrabbit.oak.spi.state.NodeStore;

import static org.apache.jackrabbit.oak.segment.file.FileStoreBuilder.fileStoreBuilder;

public class StateExporter {

    static final String FORMAT = "oak-chain-state-export-v1";
    static final String NO_BLOBSTORE = "without specifying BlobStore";

    /** Traversal or open failure: exit 2. */
    static final class ExportFailure extends Exception {
        final String path;

        ExportFailure(String message, String path, Throwable cause) {
            super(message, cause);
            this.path = path;
        }
    }

    /** --max-nodes exceeded: exit 3. */
    static final class LimitExceeded extends Exception {
        final String path;

        LimitExceeded(String message, String path) {
            super(message);
            this.path = path;
        }
    }

    private final boolean skipHidden;
    private final long maxNodes;
    private long nodeCount;
    private long propertyCount;
    private final List<Object> unreadableBinaries = new ArrayList<>();

    StateExporter(boolean skipHidden, long maxNodes) {
        this.skipHidden = skipHidden;
        this.maxNodes = maxNodes;
    }

    public static void main(String[] args) {
        // Keep stdout for the JSON result only: anything else that writes to System.out
        // (logback's default console appender, stray prints) goes to stderr.
        PrintStream stdout = new PrintStream(new java.io.FileOutputStream(java.io.FileDescriptor.out), true, StandardCharsets.UTF_8);
        System.setOut(System.err);
        quietLogging();

        String url = null;
        List<String> paths = new ArrayList<>();
        long maxNodes = Long.MAX_VALUE;
        boolean skipHidden = false;
        try {
            for (int i = 0; i < args.length; i++) {
                switch (args[i]) {
                    case "--url" -> url = args[++i];
                    case "--path" -> paths.add(args[++i]);
                    case "--max-nodes" -> maxNodes = Long.parseLong(args[++i]);
                    case "--skip-hidden" -> skipHidden = true;
                    default -> throw new IllegalArgumentException("unknown argument " + args[i]);
                }
            }
            if (url == null) throw new IllegalArgumentException("--url is required");
            if (maxNodes < 1) throw new IllegalArgumentException("--max-nodes must be >= 1");
            if (paths.isEmpty()) paths.add("/");
            for (String p : paths) {
                if (!p.startsWith("/") || (p.length() > 1 && p.endsWith("/")) || p.contains("//")) {
                    throw new IllegalArgumentException("invalid path " + p);
                }
            }
        } catch (RuntimeException e) {
            stdout.println(error(url, "usage: " + e.getMessage(), null));
            System.exit(1);
            return;
        }

        int exit;
        String out;
        Path tempDir = null;
        try {
            tempDir = Files.createTempDirectory("oak-state-export-");
            out = new StateExporter(skipHidden, maxNodes).run(url, paths, tempDir.toFile());
            exit = 0;
        } catch (ExportFailure e) {
            out = error(url, e.getMessage(), e.path);
            exit = 2;
        } catch (LimitExceeded e) {
            out = error(url, e.getMessage(), e.path);
            exit = 3;
        } catch (Throwable e) {
            out = error(url, describe(e), null);
            exit = 2;
        } finally {
            deleteQuietly(tempDir);
        }
        stdout.println(out);
        stdout.flush();
        // HTTP/2 client threads may be non-daemon; the result is already written.
        System.exit(exit);
    }

    String run(String url, List<String> paths, File tempDir) throws ExportFailure, LimitExceeded {
        HttpPersistence persistence = new HttpPersistence(url);
        String head;
        try (JournalReader reader = new JournalReader(persistence.getJournalFile())) {
            if (!reader.hasNext()) throw new ExportFailure("journal is empty", null, null);
            head = reader.next().getRevision();
        } catch (IOException | RuntimeException e) {
            throw new ExportFailure("cannot read journal head: " + describe(e), null, e);
        }

        ReadOnlyFileStore fileStore;
        try {
            fileStore = fileStoreBuilder(tempDir).withCustomPersistence(persistence).buildReadOnly();
        } catch (Exception e) {
            throw new ExportFailure("cannot open read-only store: " + describe(e), null, e);
        }
        try {
            // Pin the view to the journal head recorded above, not whatever the builder saw.
            fileStore.setRevision(head);
            NodeStore store = SegmentNodeStoreBuilders.builder(fileStore).build();
            NodeState root = store.getRoot();

            MountReadFailures.begin();
            Map<String, Object> trees = new TreeMap<>();
            Map<String, Object> pathDigests = new TreeMap<>();
            try {
                for (String path : paths) {
                    if (trees.containsKey(path)) continue;
                    NodeState start = resolve(root, path);
                    Map<String, Object> tree = node(start, path.equals("/") ? "" : path.substring(path.lastIndexOf('/') + 1), path);
                    List<MountReadFailures.Failure> failures = MountReadFailures.current();
                    if (!failures.isEmpty()) {
                        throw new ExportFailure("remote segment reads failed: " + failures, path, null);
                    }
                    trees.put(path, tree);
                    pathDigests.put(path, sha256(canonical(tree)));
                }
            } finally {
                MountReadFailures.end();
            }

            Map<String, Object> result = new LinkedHashMap<>();
            result.put("format", FORMAT);
            result.put("url", url);
            result.put("headRevision", head);
            result.put("paths", new ArrayList<>(trees.keySet()));
            result.put("skipHidden", skipHidden);
            result.put("nodeCount", nodeCount);
            result.put("propertyCount", propertyCount);
            result.put("canonicalSha256", sha256(canonical(trees)));
            result.put("pathSha256", pathDigests);
            result.put("unreadableBinaries", unreadableBinaries);
            result.put("trees", trees);
            return canonical(result);
        } finally {
            try {
                fileStore.close();
            } catch (Exception ignored) {
                // read-only store; nothing to flush
            }
        }
    }

    private static NodeState resolve(NodeState root, String path) throws ExportFailure {
        NodeState node = root;
        if (path.equals("/")) return node;
        for (String name : path.substring(1).split("/")) {
            try {
                node = node.getChildNode(name);
            } catch (RuntimeException e) {
                throw new ExportFailure("cannot resolve path: " + describe(e), path, e);
            }
            if (!node.exists()) throw new ExportFailure("path does not exist", path, null);
        }
        return node;
    }

    private Map<String, Object> node(NodeState state, String name, String path) throws ExportFailure, LimitExceeded {
        if (++nodeCount > maxNodes) {
            throw new LimitExceeded("max-nodes " + maxNodes + " exceeded", path);
        }
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("name", name);
        try {
            List<PropertyState> properties = new ArrayList<>();
            for (PropertyState p : state.getProperties()) properties.add(p);
            properties.sort(Comparator.comparing(PropertyState::getName));
            List<Object> props = new ArrayList<>();
            for (PropertyState p : properties) {
                props.add(property(p, path));
                propertyCount++;
            }
            out.put("properties", props);

            List<String> names = new ArrayList<>();
            for (String child : state.getChildNodeNames()) {
                if (skipHidden && child.startsWith(":")) continue;
                names.add(child);
            }
            names.sort(String::compareTo);
            List<Object> children = new ArrayList<>();
            for (String child : names) {
                String childPath = path.equals("/") ? "/" + child : path + "/" + child;
                NodeState childState = state.getChildNode(child);
                if (!childState.exists()) {
                    throw new ExportFailure("listed child does not exist", childPath, null);
                }
                children.add(node(childState, child, childPath));
            }
            out.put("children", children);
        } catch (ExportFailure | LimitExceeded e) {
            throw e;
        } catch (RuntimeException e) {
            throw new ExportFailure("traversal failed: " + describe(e), path, e);
        }
        return out;
    }

    private Map<String, Object> property(PropertyState p, String path) throws ExportFailure {
        Type<?> type = p.getType();
        boolean array = p.isArray();
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("name", p.getName());
        out.put("type", (array ? type.getBaseType() : type).toString());
        out.put("array", array);
        List<Object> values = new ArrayList<>();
        int count = p.count();
        for (int i = 0; i < count; i++) {
            if (type.tag() == Type.BINARY.tag()) {
                Blob blob = array ? p.getValue(Type.BINARY, i) : p.getValue(Type.BINARY);
                values.add(binary(blob, path, p.getName(), i));
            } else {
                values.add(array ? p.getValue(Type.STRING, i) : p.getValue(Type.STRING));
            }
        }
        out.put("values", values);
        return out;
    }

    private Map<String, Object> binary(Blob blob, String path, String property, int index) throws ExportFailure {
        String where = path + "/@" + property + "[" + index + "]";
        Map<String, Object> out = new LinkedHashMap<>();
        String identity;
        boolean inlined;
        try {
            identity = blob.getContentIdentity();
            inlined = blob.isInlined();
        } catch (RuntimeException e) {
            throw new ExportFailure("binary identity unreadable at " + where + ": " + describe(e), path, e);
        }
        out.put("contentIdentity", identity);
        out.put("inlined", inlined);
        // contentIdentity is the blob id; null means the bytes live in the segment store.
        boolean segmentStored = identity == null;
        out.put("segmentStored", segmentStored);
        if (segmentStored) {
            try {
                out.put("reference", blob.getReference());
                long length = blob.length();
                MessageDigest digest = newDigest();
                long read = 0;
                try (InputStream in = blob.getNewStream()) {
                    byte[] buffer = new byte[8192];
                    int n;
                    while ((n = in.read(buffer)) != -1) {
                        digest.update(buffer, 0, n);
                        read += n;
                    }
                }
                if (read != length) {
                    throw new ExportFailure("binary length " + length + " but streamed " + read + " bytes at " + where, path, null);
                }
                out.put("length", length);
                out.put("sha256", HexFormat.of().formatHex(digest.digest()));
            } catch (ExportFailure e) {
                throw e;
            } catch (IOException | RuntimeException e) {
                throw new ExportFailure("segment-stored binary unreadable at " + where + ": " + describe(e), path, e);
            }
            return out;
        }
        // External blob: reference, length and bytes all need a BlobStore this export does not have.
        try {
            out.put("reference", blob.getReference());
            out.put("length", blob.length());
        } catch (IllegalStateException e) {
            if (e.getMessage() == null || !e.getMessage().contains(NO_BLOBSTORE)) {
                throw new ExportFailure("external binary unreadable at " + where + ": " + describe(e), path, e);
            }
            String reason = "external blob: no BlobStore in read-only HTTP export; reference, length and bytes unavailable";
            out.remove("reference");
            out.remove("length");
            out.put("unreadable", reason);
            Map<String, Object> entry = new LinkedHashMap<>();
            entry.put("path", path);
            entry.put("property", property);
            entry.put("index", index);
            entry.put("contentIdentity", identity);
            entry.put("reason", reason);
            unreadableBinaries.add(entry);
        } catch (RuntimeException e) {
            throw new ExportFailure("external binary unreadable at " + where + ": " + describe(e), path, e);
        }
        return out;
    }

    // ---------------------------------------------------------------- canonical JSON

    /** Sorted keys, no whitespace, '"', '\\' and control chars as \\u00XX, non-ASCII as UTF-8. */
    static String canonical(Object value) {
        StringBuilder sb = new StringBuilder();
        write(sb, value);
        return sb.toString();
    }

    @SuppressWarnings("unchecked")
    private static void write(StringBuilder sb, Object value) {
        if (value == null) {
            sb.append("null");
        } else if (value instanceof String s) {
            string(sb, s);
        } else if (value instanceof Boolean || value instanceof Integer || value instanceof Long) {
            sb.append(value);
        } else if (value instanceof Map<?, ?> map) {
            TreeMap<String, Object> sorted = new TreeMap<>((Map<String, Object>) map);
            sb.append('{');
            boolean first = true;
            for (Map.Entry<String, Object> e : sorted.entrySet()) {
                if (!first) sb.append(',');
                first = false;
                string(sb, e.getKey());
                sb.append(':');
                write(sb, e.getValue());
            }
            sb.append('}');
        } else if (value instanceof List<?> list) {
            sb.append('[');
            for (int i = 0; i < list.size(); i++) {
                if (i > 0) sb.append(',');
                write(sb, list.get(i));
            }
            sb.append(']');
        } else {
            throw new IllegalArgumentException("not serializable: " + value.getClass());
        }
    }

    private static void string(StringBuilder sb, String s) {
        sb.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '"' || c == '\\' || c < 0x20 || c == 0x7f) {
                sb.append(String.format("\\u%04x", (int) c));
            } else if (Character.isHighSurrogate(c) && i + 1 < s.length() && Character.isLowSurrogate(s.charAt(i + 1))) {
                sb.append(c).append(s.charAt(++i));
            } else if (Character.isSurrogate(c)) {
                // Unpaired surrogate has no UTF-8 form; escape it so the value stays exact.
                sb.append(String.format("\\u%04x", (int) c));
            } else {
                sb.append(c);
            }
        }
        sb.append('"');
    }

    static String sha256(String canonical) {
        return HexFormat.of().formatHex(newDigest().digest(canonical.getBytes(StandardCharsets.UTF_8)));
    }

    private static MessageDigest newDigest() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 unavailable", e);
        }
    }

    // ---------------------------------------------------------------- support

    private static String error(String url, String message, String path) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("format", FORMAT);
        out.put("url", url);
        out.put("error", message);
        out.put("path", path);
        return canonical(out);
    }

    private static String describe(Throwable e) {
        StringBuilder sb = new StringBuilder();
        for (Throwable t = e; t != null; t = t.getCause()) {
            if (sb.length() > 0) sb.append(" <- ");
            sb.append(t.getClass().getSimpleName());
            if (t.getMessage() != null) sb.append(": ").append(t.getMessage());
            if (t.getCause() == t) break;
        }
        return sb.toString();
    }

    private static void quietLogging() {
        try {
            org.slf4j.Logger root = org.slf4j.LoggerFactory.getLogger(org.slf4j.Logger.ROOT_LOGGER_NAME);
            if (root instanceof ch.qos.logback.classic.Logger logback) {
                logback.setLevel(ch.qos.logback.classic.Level.WARN);
            }
        } catch (Throwable ignored) {
            // logging is best effort; stdout is already redirected
        }
    }

    private static void deleteQuietly(Path dir) {
        if (dir == null) return;
        try (Stream<Path> walk = Files.walk(dir)) {
            walk.sorted(Comparator.reverseOrder()).forEach(p -> p.toFile().delete());
        } catch (IOException ignored) {
            // temp dir cleanup is best effort
        }
    }
}
