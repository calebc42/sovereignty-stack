sed 's/__STEP__/$1/g' templates/step-ci.yml.stub > .github/workflows/step-$1.yml
