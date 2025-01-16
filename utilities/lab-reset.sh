#!/usr/bin/env bash
#

echo "Killing pod..."

docker kill showroom-httpd

echo "Removing old site..."
rm -rf ./www/*
echo "Old site removed"

echo "Building new site"
npx antora --fetch default-site.yml

echo "Starting serve process..."

docker run -d --rm --name showroom-httpd -p 8080:8080 \
  -v "./www:/var/www/html/:z" \
  registry.access.redhat.com/ubi9/httpd-24:1-301

echo "Serving lab content on http://localhost:8080/index.html"