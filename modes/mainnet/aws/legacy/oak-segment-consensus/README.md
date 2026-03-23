# AWS Onwards-To-Production Checklist (oak-segment-consensus)

Imported from the former top-level
`/Users/mhess/aem/aem-code/OAK/oak-segment-consensus/` folder on 2026-03-23.
This is legacy reference material, not the canonical home for new AWS infra
work.

This is a pragmatic, shortest-path checklist for a standalone deployment on AWS with room to harden later.

## Phase 1: Minimal Production-Ready Deploy

1. **Account & IAM**
   1. Create an AWS account (or use existing).
   2. Create an IAM user/role for Terraform with least-privilege (VPC, EC2, EFS, ELB, EB, IAM for EB roles).

2. **Domain & TLS**
   1. Register or choose a domain.
   2. Provision a certificate in ACM for `your.domain.example`.

3. **Networking**
   1. Create a VPC with public subnets (2 AZs).
   2. Attach an Internet Gateway and route table.

4. **Storage (Persistent)**
   1. Create EFS.
   2. Create mount targets in each subnet.
   3. Plan mount points:
      - Segment store (e.g., `/var/oak-chain/segmentstore`)
      - Proposal persistence (e.g., `/var/oak-chain/proposals`)

5. **Compute (Elastic Beanstalk, Docker)**
   1. Create EB application.
   2. Create EB environment:
      - Load Balancer type: ALB
      - Instance type: `t3.large` (or larger)
      - Health check path: `/v1/health`
   3. Deploy container image (ECR or Docker Hub).

6. **Security**
   1. ALB security group: allow `443` from the internet.
   2. Instance security group: allow `8090` from ALB only.
   3. Enforce auth (token or mTLS) at the edge or app.

7. **Config Management**
   1. Provide OSGi `.cfg` files under a mounted `config/` directory.
   2. Ensure container reads config from file-based OSGi config.

8. **Observability**
   1. Send app logs to CloudWatch.
   2. Enable ALB access logs to S3.
   3. Set CloudWatch alarms for 5xx, latency, and CPU.

9. **Deployment Safety**
   1. Enable rolling deployments.
   2. Keep one previous image available for rollback.

## Phase 2: Hardening

1. Add WAF with rate limiting and IP allow lists.
2. Add strict allowlist for public API paths.
3. Add backups (EFS backup policy or snapshots).
4. Add environment separation (dev/stage/prod).
5. Add synthetic checks (external).

## Phase 3: Scale & HA

1. Multi-AZ deployment.
2. Autoscaling based on queue depth and CPU.
3. Load testing and tuning iteration.

---

## Terraform Skeleton

See `terraform/` for a starter layout. It is intentionally light and uses variables to avoid pinning runtime-specific values.

**Important**: Elastic Beanstalk in Terraform often needs extra EB settings and `.ebextensions` for EFS mounts. This skeleton includes EFS and core networking; you will need to wire the EFS mount within the EB environment or use a custom AMI/launch config.
