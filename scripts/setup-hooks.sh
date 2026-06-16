#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# Setup Pre-Commit Hooks
# ═══════════════════════════════════════════════════════════════════════════════

set -e

echo "🔧 Setting up pre-commit hooks..."

# Make hooks executable
chmod +x .pi/hooks/pre-commit
chmod +x .pi/hooks/commit-msg

# Configure git to use project hooks
git config core.hooksPath .pi/hooks

echo "✅ Hooks installed!"
echo ""
echo "Active hooks:"
echo "  • pre-commit  → Fast validation (types, lint, tests)"
echo "  • commit-msg  → Conventional commit format"
echo ""
echo "Test it: ./.pi/hooks/pre-commit"
echo "Bypass:   git commit --no-verify"
