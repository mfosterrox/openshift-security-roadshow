#!/usr/bin/env bash
#

echo "Starting build process..."
echo "Removing old site..."
rm -rf ./www/*
echo "Building new site..."

npx antora --fetch default-site.yml

echo "Build process complete. Check the ./www folder for the generated site."
echo "To view the site locally, run the following command: utilities/lab-serve"
echo "If already running then browse to http://localhost:8080/index.html"