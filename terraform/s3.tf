# ─────────────────────────────────────────────────────────────────────────────
#  S3: one data-lake bucket plus one artifact (deploy target) bucket.
#
#  Bucket names must be globally unique. Suffixing with the account id gives
#  determinism without needing random state:
#     data-pipeline-dev-data-123456789012
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "zone" {
  for_each = local.buckets

  bucket        = "${local.name}-${each.key}-${local.account_id}"
  force_destroy = var.destroyable

  # NOTE: `purpose` is deliberately NOT a tag. AWS tag values allow only
  # [A-Za-z0-9 _.:/=+@-]; the prose in locals.buckets contains commas and a
  # semicolon, which makes PutBucketTagging fail with InvalidTag. Prose belongs
  # in locals.tf, not in a tag value.
  tags = {
    Name = "${local.name}-${each.key}"
    Role = each.key
  }
}

# Versioning preserves previous data objects and artifact versions.
resource "aws_s3_bucket_versioning" "zone" {
  for_each = local.buckets

  bucket = aws_s3_bucket.zone[each.key].id

  versioning_configuration {
    status = each.value.versioning ? "Enabled" : "Suspended"
  }
}

# SSE-S3 keeps the replica simple. A production environment may use SSE-KMS so
# key policy becomes a second authorisation layer.
resource "aws_s3_bucket_server_side_encryption_configuration" "zone" {
  for_each = local.buckets

  bucket = aws_s3_bucket.zone[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "zone" {
  for_each = local.buckets

  bucket = aws_s3_bucket.zone[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "zone" {
  for_each = local.buckets

  bucket = aws_s3_bucket.zone[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Deny any non-TLS request. Cheap control, and exactly the kind of thing the
# platform layer should apply for every team rather than each team remembering.
resource "aws_s3_bucket_policy" "deny_insecure_transport" {
  for_each = local.buckets

  bucket = aws_s3_bucket.zone[each.key].id
  policy = data.aws_iam_policy_document.deny_insecure_transport[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.zone]
}

data "aws_iam_policy_document" "deny_insecure_transport" {
  for_each = local.buckets

  statement {
    sid    = "DenyUnencryptedTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.zone[each.key].arn,
      "${aws_s3_bucket.zone[each.key].arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "zone" {
  for_each = local.buckets

  bucket = aws_s3_bucket.zone[each.key].id

  # Orphaned multipart parts are billed but invisible in the console. Always clean.
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  dynamic "rule" {
    for_each = (
      each.value.transition_ia_days > 0 ||
      each.value.expire_days > 0 ||
      each.value.noncurrent_expire_days > 0
    ) ? [each.value] : []

    content {
      id     = "zone-retention"
      status = "Enabled"

      filter {}

      dynamic "transition" {
        for_each = rule.value.transition_ia_days > 0 ? [1] : []
        content {
          days          = rule.value.transition_ia_days
          storage_class = "STANDARD_IA"
        }
      }

      dynamic "expiration" {
        for_each = rule.value.expire_days > 0 ? [1] : []
        content {
          days = rule.value.expire_days
        }
      }

      dynamic "noncurrent_version_expiration" {
        for_each = rule.value.noncurrent_expire_days > 0 ? [1] : []
        content {
          noncurrent_days = rule.value.noncurrent_expire_days
        }
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.zone]
}
