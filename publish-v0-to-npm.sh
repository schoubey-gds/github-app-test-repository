#!/usr/bin/env bash

set -e

# Use this script to publish a new package to npm. The package is published as v0.0.0 and is independent of
# any packages with the same name that you may have defined in the packages directory. That means any WIP
# code will not be published, only the bare-minimum package.json necessary to bootstrap the package in the
# registry.

# npm publish should ask you to log in with a browser automatically, so there is no need to provide an npm token.

ORGANISATION=schoubey-gds

echo "Be sure to execute this function in the root of the repository, ideally with 'npm run publish-v0-to-npm'."

read -p "Scoped package name (exclude @$ORGANISATION/): " NAME

mkdir -p publish-temp/$NAME
cd publish-temp/$NAME

echo "{
  \"name\": \"@$ORGANISATION/$NAME\",
  \"version\": \"0.0.0\"
}
" >> package.json

npm publish --access public || (cd ../.. && rm -r publish-temp)

cd ../..

rm -r publish-temp

echo "Package published. Now go set up OIDC. 👋"

open https://www.npmjs.com/package/@$ORGANISATION/$NAME/access