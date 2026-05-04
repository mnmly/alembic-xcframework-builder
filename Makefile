ALEMBIC_VERSION ?=

.PHONY: xcframework release clean distclean check-version

xcframework: check-version
	./build.sh $(ALEMBIC_VERSION)

release: check-version
	RELEASE=1 ./build.sh $(ALEMBIC_VERSION)

check-version:
	@if [ -z "$(ALEMBIC_VERSION)" ]; then \
		echo "Usage: make ALEMBIC_VERSION=1.8.11 [xcframework|release]"; \
		exit 1; \
	fi

clean:
	rm -rf work

distclean: clean
	rm -rf output
