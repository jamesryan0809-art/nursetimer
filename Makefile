# NurseTimer — project generation
#
# `make project` regenerates NurseTimer.xcodeproj from project.yml via XcodeGen.
# The .xcodeproj is generated (git-ignored), so the declarative project.yml is the
# single source of truth.

XCODEGEN := $(shell command -v xcodegen 2>/dev/null)

.PHONY: project
project:
	@if [ -z "$(XCODEGEN)" ]; then \
	  echo "✗ XcodeGen not found."; \
	  echo ""; \
	  echo "  Install one of:"; \
	  echo "    brew install xcodegen"; \
	  echo "    mint install yonaskolb/XcodeGen@2.43.0   # pinned/tested version"; \
	  echo ""; \
	  echo "  Docs: https://github.com/yonaskolb/XcodeGen"; \
	  exit 1; \
	fi
	@echo "→ Generating NurseTimer.xcodeproj from project.yml …"
	xcodegen generate --spec project.yml
	@echo "✅ Done. Open NurseTimer.xcodeproj in Xcode 16+, select signing teams, and build."

.PHONY: help
help:
	@echo "make project   Generate NurseTimer.xcodeproj from project.yml (needs XcodeGen)"
