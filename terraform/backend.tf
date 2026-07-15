# =============================================================================
# Remote state (GCS backend)
# =============================================================================
#
# WHY THIS EXISTS
# ---------------
# Terraform state used to be a file on whoever ran the deploy. That made the
# deploy machine-dependent in a way that bites hard and silently:
#
#   PC A: ./deploy.sh my-project        -> works, state lands in PC A
#   PC B: ./deploy.sh my-project        -> state is EMPTY here, so Terraform
#                                          believes nothing exists and tries to
#                                          create everything from scratch
#
# deploy.sh imports the dataset / connection / linked dataset before applying,
# so those survive the round trip. The BigQuery *jobs* do not: their job_id is
# a sha256 of the SQL they run, and BigQuery job ids are unique per
# project+location forever. Re-creating an unchanged job therefore fails with:
#
#   Already Exists: Job my-project:US.create_model_gemini_flash_<sha>
#
# (verified against the live API). The apply dies there — resources are not
# "recreated", the deploy simply stops. Keeping state in GCS instead means
# every machine reads the same state and a redeploy does what you expect:
# apply only what actually changed.
#
# WHY THE BLOCK IS EMPTY
# ----------------------
# Terraform does not allow variables or interpolation inside a backend block —
# it is read before the rest of the config is even parsed, so `bucket =
# "${var.project_id}-tfstate"` is a hard error. The values are therefore
# supplied at init time as partial configuration, which deploy.sh does for you:
#
#   terraform init \
#     -backend-config="bucket=<PROJECT_ID>-tfstate" \
#     -backend-config="prefix=gemini-ent-dashboard"
#
# deploy.sh also creates that bucket (versioned, uniform access, public access
# prevented) on first run — Terraform cannot create the bucket that holds its
# own state, so it has to exist before init.
#
# MIGRATING AN EXISTING LOCAL STATE
# ---------------------------------
# If you already deployed with local state, run this ONCE from the machine
# holding terraform.tfstate — it uploads what you have instead of starting
# empty (otherwise that machine's knowledge of the BigQuery jobs is lost and
# the next deploy hits the 409 above):
#
#   terraform -chdir=terraform init -migrate-state \
#     -backend-config="bucket=<PROJECT_ID>-tfstate" \
#     -backend-config="prefix=gemini-ent-dashboard"
#
# If that state is already gone, see the "state is lost" recovery note in
# README.md — the BigQuery jobs have to be imported by hand once.

terraform {
  backend "gcs" {}
}
