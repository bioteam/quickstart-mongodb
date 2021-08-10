#/bin/bash

aws s3 cp submodules/quickstart-aws-vpc/templates/aws-vpc.template.yaml s3://mongo-db-sharded/mongo-db-sharded/submodules/quickstart-aws-vpc/templates/
aws s3 cp submodules/quickstart-linux-bastion/templates/linux-bastion.template s3://mongo-db-sharded/mongo-db-sharded/submodules/quickstart-linux-bastion/templates/
aws s3 cp submodules/quickstart-linux-bastion/scripts s3://mongo-db-sharded/mongo-db-sharded/submodules/quickstart-linux-bastion/scripts --recursive
aws s3 cp templates/mongodb.template s3://mongo-db-sharded/mongo-db-sharded/templates/
aws s3 cp templates/mongodb-node.template s3://mongo-db-sharded/mongo-db-sharded/templates/
aws s3 cp templates/mongodb-master.template s3://mongo-db-sharded/mongo-db-sharded/templates/
aws s3 cp scripts s3://mongo-db-sharded/mongo-db-sharded/scripts --recursive
