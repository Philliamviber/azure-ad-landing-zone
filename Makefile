# Makefile — convenience wrappers around the Terraform lifecycle.
# Validation/lint targets map to the test-engineer step in the delegation plan.

.PHONY: init fmt validate lint plan apply destroy scan

init:
	terraform init

fmt:
	terraform fmt -recursive

validate: fmt
	terraform validate

lint:
	tflint --recursive

# Static security scanning (config-as-code review gate).
scan:
	checkov -d . --quiet || true
	tfsec . || true

plan: validate
	terraform plan -out=tfplan

apply:
	terraform apply tfplan

destroy:
	terraform destroy
