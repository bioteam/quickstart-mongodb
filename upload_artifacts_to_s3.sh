#/bin/bash -e

repo_root=$(dirname "$(realpath $0)")
rm -r $repo_root/build

mkdir -p $repo_root/build
mkdir -p $repo_root/build/templates

sed -e '/^\s*\/\*/,/\*\/$/d' -e '/^\s*\/\//d' templates/mongodb.template > build/templates/mongodb.template
sed -e '/^\s*\/\*/,/\*\/$/d' -e '/^\s*\/\//d' templates/mongodb-replicaset.template > build/templates/mongodb-replicaset.template

aws s3 cp submodules/quickstart-aws-vpc/templates/aws-vpc.template.yaml s3://mongo-db-sharded/mongo-db-sharded/submodules/quickstart-aws-vpc/templates/
aws s3 cp submodules/quickstart-linux-bastion/templates/linux-bastion.template s3://mongo-db-sharded/mongo-db-sharded/submodules/quickstart-linux-bastion/templates/
aws s3 cp submodules/quickstart-linux-bastion/scripts s3://mongo-db-sharded/mongo-db-sharded/submodules/quickstart-linux-bastion/scripts --recursive
aws s3 cp build/templates/mongodb.template s3://mongo-db-sharded/mongo-db-sharded/templates/
aws s3 cp build/templates/mongodb-replicaset.template s3://mongo-db-sharded/mongo-db-sharded/templates/
aws s3 cp templates/mongodb-node.template s3://mongo-db-sharded/mongo-db-sharded/templates/
aws s3 cp templates/mongodb-vpc.template s3://mongo-db-sharded/mongo-db-sharded/templates/
aws s3 cp scripts s3://mongo-db-sharded/mongo-db-sharded/scripts --recursive
