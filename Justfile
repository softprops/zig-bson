# fetch the latest specs
sync-specs:
    @mkdir -p tmp
    @curl -sL https://github.com/mongodb/specifications/archive/master.zip -o "./tmp/specs.zip"
    @unzip -od ./tmp ./tmp/specs.zip > /dev/null
    @rsync -ah ./tmp/specifications-master/source/bson-corpus/tests \
        --exclude="bsonview" \
        specs/bson-corpus \
        --delete
    @rm -rf ./tmp