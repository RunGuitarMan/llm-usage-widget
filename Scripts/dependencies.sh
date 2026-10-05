# Shared framework input for script builds, UI checks, and Xcode.
python3 Scripts/prepare-dependencies.py >/dev/null
LLM_SPARKLE_DIRECTORY="$PWD/build/Dependencies/current/sparkle"
LLM_SPARKLE_FLAGS=(-F "$LLM_SPARKLE_DIRECTORY" -framework Sparkle
                   -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
