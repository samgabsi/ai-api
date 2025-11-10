#!/bin/bash
set -e

PROJECT_PATH="/Users/sam/Desktop/NeuroDeskAI_Full/NeuroDesk AI"
REPO_URL="https://github.com/samgabsi/ai-api.git"

echo "🔍 Checking Git setup for NeuroDesk AI..."
cd "$PROJECT_PATH"

# Check if git initialized
if [ -d ".git" ]; then
    echo "✅ Git already initialized."
else
    echo "🚀 Initializing Git..."
    git init
fi

# Check if remote exists
REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)
if [ -z "$REMOTE_URL" ]; then
    echo "🔗 Adding remote origin..."
    git remote add origin "$REPO_URL"
else
    echo "ℹ️ Existing remote found: $REMOTE_URL"
fi

# Create .gitignore if missing
if [ ! -f ".gitignore" ]; then
    echo "🧹 Creating .gitignore..."
    cat > .gitignore <<'EOF'
# macOS
.DS_Store
.AppleDouble
.LSOverride
Icon?
._*

# Xcode
build/
DerivedData/
*.xcworkspace/xcuserdata/
*.xcodeproj/project.xcworkspace/
*.xcodeproj/xcuserdata/
*.xcuserstate
*.xcuserdatad
*.xccheckout
*.moved-aside
*.ipa
*.dSYM*
*.xcarchive

# SwiftPM
.swiftpm/
.build/

# CocoaPods
Pods/
Podfile.lock

# Carthage
Carthage/Build/

# Fastlane
fastlane/report.xml
fastlane/Preview.html
fastlane/screenshots/**/*.png

# Other
*.log
*.env
EOF
else
    echo "✅ .gitignore already exists."
fi

# Commit and sync
echo "📦 Preparing initial commit and sync..."
git add .
git commit -m "Auto-link NeuroDesk AI to ChatGPT project repo" || echo "🟡 Nothing new to commit."
git branch -M main
git pull origin main --allow-unrelated-histories || echo "🟡 Could not pull (maybe empty remote)."
git push -u origin main

echo "✅ NeuroDesk AI successfully linked to $REPO_URL"

