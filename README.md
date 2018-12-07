# mongo-cluster-topology
Simple bash script for a quick overview of the topology of a sharded MongoDB cluster

It will give you:
- The list and status of your mongos
- The list and status of your config server
- The list and status of every replica set members present in your cluster (including secondary members and arbiters), plus:
  - The date of the last role change between primary and secondary
  - The apply lag between primary and all secondary members
  - The oplog window
- The balancer status

# Usage
See [MongoDB sharded cluster topology on My DBA World](https://www.mydbaworld.com/mongodb-sharded-cluster-topology/)
