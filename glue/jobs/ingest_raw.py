#!/usr/bin/env python3
"""
ingest_raw.py  --  landing -> raw   (Glue PySpark job, stage 2 of 6)
====================================================================

WHAT THIS STAGE IS FOR
----------------------
Turn an untrusted supplier file into an immutable, typed, partitioned record of
*what arrived*. Nothing more. In particular:

  *  It does NOT deduplicate. If the supplier sent ACC100027 twice, BOTH rows
     land in `raw`. Deciding which one is true is a business judgement and it
     belongs in the next stage. `raw` answers "what did they say", not
     "what is true".
  *  It does NOT conform. ' GB ' stays ' GB '. Upper-casing and validating
     against the country reference set happens in curate.py.

Those two restraints are the whole reason `raw` exists. If ingest also cleaned,
there would be nothing to replay from when the cleaning logic turns out to be
wrong.

WHAT IT DOES DO
---------------
  1. Assert the CSV header matches the agreed contract, exactly and in order.
  2. Enforce types. Strings become dates, doubles, timestamps.
  3. Quarantine anything that will not parse -- with the reason -- to
     landing/_rejects/. Rejects are never silently dropped: a malformed row is
     someone's job to chase.
  4. Write typed Parquet, partitioned by business date.

ABSENT vs MALFORMED -- the distinction that matters
---------------------------------------------------
An empty credit_limit is allowed through as null: the supplier legitimately has
no value. A credit_limit of "not-a-number" is quarantined. Both end up as null
if you just cast, which is why casting alone is not validation -- the two have
different root causes and different owners.

ARTIFACT / DEPLOY (the CI/CD point)
-----------------------------------
  artifact  : this .py file. That is all. No wheel, no zip, no image.
  build     : none. There is nothing to compile or package.
  deploy    : upload to `s3://<artifacts>/glue-scripts/<pipeline>/<sha>/...`
  runtime   : Glue downloads this file onto the Spark driver at job start and
              executes it. CD selects its key using StartJobRun's supported
              `--scriptLocation` override; Terraform owns only the job shell.

S3 does not enforce immutability like ECR. The release contract therefore
never overwrites a SHA-addressed key, and the Job Run arguments provide the
artifact-to-execution record.

This job deliberately has NO dependency on the shared wheel -- it is the pure
"plain .py, zero build" case. curate.py is where `--extra-py-files` and the
cross-component coupling appear.

PORTABILITY
-----------
Written against plain `pyspark.sql`, not Glue DynamicFrames. The only
Glue-specific lines are the argument parsing and job bookkeeping below. That is
deliberate: the same transformation must be able to run on EMR-on-EKS, where
the artifact becomes a container image instead of an S3 object. Bind the logic
to DynamicFrames and the compute step stops being pluggable.
"""

import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F

# ─────────────────────────────────────────────────────────────────────────────
#  The data contract.
#
#  Duplicated here on purpose. In the real pipeline this list comes from the
#  shared wheel (dp_common.schema.LANDING_COLUMNS) and that import is what makes
#  a wheel bump a cross-component event. Inlined for this first job so the
#  "plain .py, no build" case stays genuinely dependency-free.
# ─────────────────────────────────────────────────────────────────────────────

LANDING_COLUMNS = [
    "account_id",
    "customer_id",
    "country",
    "opened_date",
    "credit_limit",
    "balance",
    "status",
    "updated_at",
]

DATE_FMT = "yyyy-MM-dd"
TS_FMT = "yyyy-MM-dd'T'HH:mm:ss"

args = getResolvedOptions(
    sys.argv,
    ["JOB_NAME", "source_uri", "raw_uri", "rejects_uri", "business_date", "run_id"],
)

sc = SparkContext.getOrCreate()
glue_context = GlueContext(sc)
spark = glue_context.spark_session
job = Job(glue_context)
job.init(args["JOB_NAME"], args)

# Re-running a business date must replace that date, not append to it. Without
# dynamic partition overwrite, a replay doubles the partition and every
# downstream count is silently wrong -- the same failure mode as a missed
# dedupe, arriving by a different route.
spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")

# This job's contract is "bad data becomes null, then gets quarantined" -- it
# must never die on a malformed value. Pin the parser policy explicitly rather
# than inheriting whatever the Glue version defaults to: under CORRECTED, an
# unparseable date yields null, which is exactly what the checks below test for.
spark.conf.set("spark.sql.legacy.timeParserPolicy", "CORRECTED")
spark.conf.set("spark.sql.ansi.enabled", "false")

# ── 1. Read everything as text ───────────────────────────────────────────────
#
# inferSchema is off deliberately. Inference costs an extra pass over the data
# and, worse, makes the schema a property of today's file rather than of the
# contract: one all-null column and tomorrow's types differ from today's.

raw_text = (
    spark.read.option("header", "true")
    .option("inferSchema", "false")
    .option("mode", "PERMISSIVE")
    .csv(args["source_uri"])
)

if raw_text.columns != LANDING_COLUMNS:
    raise ValueError(
        "landing header does not match the contract.\n"
        f"  expected: {LANDING_COLUMNS}\n"
        f"  received: {raw_text.columns}\n"
        "The arrival Lambda should have caught this in ~200ms before any Spark "
        "capacity was paid for. If it did not, that gate has a hole in it."
    )

# ── 2. Validate, field by field ──────────────────────────────────────────────


def _present(name):
    """Non-null and not blank. Blank means 'supplier had no value'."""
    col = F.col(name)
    return col.isNotNull() & (F.trim(col) != F.lit(""))


def _not_numeric(name):
    """Present, but will not cast to a double."""
    return _present(name) & F.col(name).cast("double").isNull()


def _not_a_date(name, fmt):
    """Present, but not strict ISO-8601. 03/04/2026 is ambiguous, so rejected."""
    return _present(name) & F.to_timestamp(F.trim(F.col(name)), fmt).isNull()


# Each check contributes a reason string, or nothing. Collecting reasons rather
# than failing on the first one means a supplier gets the full list in one pass
# instead of discovering problems one deploy at a time.
checks = [
    (~_present("account_id"), "account_id missing"),
    (~_present("updated_at"), "updated_at missing"),
    (_not_a_date("opened_date", DATE_FMT), "opened_date not ISO-8601"),
    (_not_a_date("updated_at", TS_FMT), "updated_at not ISO-8601"),
    (_not_numeric("credit_limit"), "credit_limit not numeric"),
    (_not_numeric("balance"), "balance not numeric"),
]

problems = F.filter(
    F.array(*[F.when(cond, F.lit(reason)) for cond, reason in checks]),
    lambda x: x.isNotNull(),
)

tagged = raw_text.withColumn("_problems", problems).cache()

good = tagged.filter(F.size("_problems") == 0)
bad = tagged.filter(F.size("_problems") > 0)

# ── 3. Quarantine the rejects ────────────────────────────────────────────────
#
# Written back beside the drop, as JSON, with the reason and the source file.
# JSON not Parquet: these are for a human to read, and there will never be many.
#
# `input_file_name()` rather than a line number -- Spark reads splits in
# parallel, so a per-row line number is not cheaply available. The file plus the
# key is enough to find the row.

reject_count = bad.count()
if reject_count:
    (
        bad.withColumn("_source_file", F.input_file_name())
        .withColumn("dt", F.lit(args["business_date"]))
        .write.mode("overwrite")
        .partitionBy("dt")
        .json(args["rejects_uri"])
    )

# ── 4. Type and write the good rows ──────────────────────────────────────────
#
# Column order is fixed to the contract. `_ingested_run` is provenance: given a
# row in raw, you can always name the run that put it there.

typed = good.select(
    F.col("account_id"),
    F.col("customer_id"),
    F.col("country"),
    F.to_date(F.trim(F.col("opened_date")), DATE_FMT).alias("opened_date"),
    F.col("credit_limit").cast("double").alias("credit_limit"),
    F.col("balance").cast("double").alias("balance"),
    F.col("status"),
    F.to_timestamp(F.trim(F.col("updated_at")), TS_FMT).alias("updated_at"),
).withColumn("_ingested_run", F.lit(args["run_id"])).withColumn(
    "dt", F.lit(args["business_date"])
)

accepted_count = typed.count()

(
    typed.write.mode("overwrite")
    .partitionBy("dt")
    .parquet(args["raw_uri"])
)

# ── 5. Report ────────────────────────────────────────────────────────────────
#
# These land in CloudWatch. The distinct-account line is not a check, it is a
# reminder: rows > distinct accounts is EXPECTED here. If they were equal,
# either the supplier sent no restatements or this job is wrongly deduplicating.

distinct_accounts = typed.select("account_id").distinct().count()

print("=" * 66)
print(f"  source ............... {args['source_uri']}")
print(f"  rows accepted ........ {accepted_count}")
print(f"  rows quarantined ..... {reject_count}")
print(f"  distinct accounts .... {distinct_accounts}")
print(f"  restatements kept .... {accepted_count - distinct_accounts}  (curate collapses these)")
print(f"  written to ........... {args['raw_uri']}dt={args['business_date']}/")
print("=" * 66)

job.commit()
