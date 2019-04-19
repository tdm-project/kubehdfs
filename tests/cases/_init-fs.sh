#!/usr/bin/env bash
function run_test_case () {
  helm install  \
    hdfs-k8s  \
    -n my-hdfs  \
    --values ${_TEST_DIR}/values/common.yaml  \
    --values ${_TEST_DIR}/values/init-fs.yaml  \
    --values ${_TEST_DIR}/values/custom-hadoop-config.yaml  \
    --set "global.dataNodeHostPath={/mnt/sda1/hdfs-data0,/mnt/sda1/hdfs-data1}"

  k8s_single_pod_ready -l app=zookeeper,release=my-hdfs
  k8s_all_pods_ready 3 -l app=hdfs-journalnode,release=my-hdfs
  k8s_all_pods_ready 2 -l app=hdfs-namenode,release=my-hdfs
  k8s_single_pod_ready -l app=hdfs-datanode,release=my-hdfs
  k8s_single_pod_ready -l app=hdfs-client,release=my-hdfs
  _CLIENT=$(kubectl get pods -l app=hdfs-client,release=my-hdfs -o name |  \
      cut -d/ -f 2)
  echo Found client pod: $_CLIENT

  echo All pods:
  kubectl get pods

  echo All persistent volumes:
  kubectl get pv

  _run kubectl exec $_CLIENT -- hdfs dfsadmin -report
  _run kubectl exec $_CLIENT -- hdfs haadmin -getServiceState nn0
  _run kubectl exec $_CLIENT -- hdfs haadmin -getServiceState nn1

  [ $(_run kubectl exec $_CLIENT -- hdfs dfs -ls -d  /tmp | grep "root root" | wc -l) == 1  ]
  [ $(_run kubectl exec $_CLIENT -- hdfs dfs -ls -d  /tmp | grep "drwxrwxrwx" | wc -l) == 1  ]
  [ $(_run kubectl exec $_CLIENT -- hdfs dfs -ls -d  /user/foo | grep "foo foo" | wc -l) == 1  ]

  echo "DONE"
}

function cleanup_test_case() {
  helm delete --purge my-hdfs || true
  true
}
