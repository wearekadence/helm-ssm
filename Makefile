.PHONY: lint test test-integration

lint:
	bash -n ssm.sh
	@echo "ssm.sh: syntax OK"

test: lint

test-integration:
	@if [ -z "$$LOCALSTACK_ENDPOINT" ]; then \
		echo "LOCALSTACK_ENDPOINT not set; integration tests will be skipped."; \
	fi
	./tests/integration/run.sh
