#!/usr/bin/env bash
set -euo pipefail

# Change to your project folder
cd "$(dirname "$0")/."

# Configure your identity (run once per machine)
git config --global user.name "YOUR NAME"
git config --global user.email "YOUR_EMAIL@EXAMPLE.COM"

# Initialize the repository
git init

# Ensure .gitignore exists
if [ ! -f ".gitignore" ]; then
  cat > .gitignore <<'EOF'
# macOS
.DS_Store
.AppleDouble
.LSOverride

# Xcode
build/
DerivedData/
*.xcscmblueprint
*.xccheckout
xcuserdata/
*.xcuserstate
*.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings

# Swift Package Manager
.build/
.swiftpm/xcode/package.xcworkspace/xcuserdata/

# CocoaPods
Pods/
Podfile.lock
# Carthage
Carthage/Build/

# Archives
*.xcarchive

# Fastlane
fastlane/report.xml
fastlane/Preview.html
fastlane/screenshots
fastlane/test_output

# Bundle artifacts
*.ipa
*.dSYM.zip
*.dSYM

# User-specific
*.orig
*.rej

# Editor
.vscode/
.idea/

EOF
fi

# First commit
git add .
git commit -m "chore: initial commit"

# Set default branch to main
git branch -M main

# Connect to GitHub (pick one and replace with your repo URL):
# HTTPS:
# git remote add origin https://github.com/<your-username>/Badminton-Lab.git
# SSH:
# git remote add origin git@github.com:<your-username>/Badminton-Lab.git

echo "Now run: git push -u origin main"
