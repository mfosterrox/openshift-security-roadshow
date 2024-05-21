#!/bin/bash

# Check if the user has provided a directory as an argument
if [ -z "$1" ]; then
    echo "Usage: $0 <directory>"
    exit 1
fi

# Assign the provided directory to a variable
DIRECTORY=$1

# Ensure the provided argument is a valid directory
if [ ! -d "$DIRECTORY" ]; then
    echo "Error: $DIRECTORY is not a valid directory."
    exit 1
fi

# Find all files in the directory and its subdirectories
find "$DIRECTORY" -type f | while read -r FILE; do
    # Get the directory and filename separately
    DIR=$(dirname "$FILE")
    BASENAME=$(basename "$FILE")

    # Replace underscores with hyphens in the filename
    NEW_BASENAME=${BASENAME//_/-}

    # Rename the file if the new name is different
    if [ "$BASENAME" != "$NEW_BASENAME" ]; then
        mv "$FILE" "$DIR/$NEW_BASENAME"
        echo "Renamed: $FILE -> $DIR/$NEW_BASENAME"
    fi
done

