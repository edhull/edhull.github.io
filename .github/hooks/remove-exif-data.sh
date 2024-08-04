#!/bin/bash

echo "Running remove-exif-data pre-commit"
# Get added/modified file list
for FILE in `exec git diff --cached --name-only --diff-filter=AM` ; do
    EXT=$(echo "${FILE##*.}" | tr "[:lower:]" "[:upper:]")
    # Process JPG & PNG files. Can add additional filetypes below
    if [ "$EXT" = "JPG" ] || [ "$EXT" = "PNG" || "$EXT" = "JPEG" ] ]; then
        echo "Attempting to remove GPS data from $FILE"
        exiftool -all= -overwrite_original $FILE
        git add $FILE
    fi
done
