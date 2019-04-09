# Running the integration tests

Tests consist of the following scripts, to be executed in order:

  - `setup.sh`: runs initial setup, such as installing and starting Minikube
  - `run.sh`: launches the charts on Minikube and tests them
  - `cleanup.sh`: shuts down the HDFS cluster and deletes related k8s resources
  - `teardown.sh`: stops and deletes the Minikube instance

The above sequence is meant for running everything from scratch (e.g., on
Travis). When running tests as part of the development cycle, you probably
want to avoid re-running the first and last steps, so that you can keep using
the same Minikube instance. In this case, to get a clean state between
subsequent tests, you can delete persistent volumes and DataNode
hostPaths. For instance:

```
kubectl delete pvc -l release=my-hdfs
minikube ssh "sudo bash -c 'rm -rf /mnt/sda1/hdfs-data/*'"
```

## Running specific test cases only

`run.sh` will run all tests under `tests/cases`. To run a single test, set the
`CASES` env var accordingly. For instance:

```
CASES=_basic.sh tests/run.sh
```

`CASES` can also be set for `cleanup.sh`:

```
CASES=_basic.sh tests/cleanup.sh
```
