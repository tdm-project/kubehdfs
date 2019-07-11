# Helm charts

Features:

 - [HDFS High Availability (HA) via Quorum Journal
   Manager]((https://hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-hdfs/HDFSHighAvailabilityWithQJM.html)). Allows
   automatic failover of the active HDFS NameNode to another standby NameNode
   in case of failures.

 - [Hadoop secure mode via
   Kerberos](https://hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-common/SecureMode.html).

 - K8s persistent volumes (PVs) for metadata: NameNodes use PVs for storage,
   so that file system metadata are not lost even if both NameNode daemons are
   restarted.

 - K8s hostPath volumes for file data: DataNodes store file data on the local
   disks of the K8s cluster nodes using hostPath volumes.


The main entry-point is `hdfs-k8s`, an umbrella chart that installs HDFS
components via subcharts:

 - `hdfs-namenode-k8s`: installs NameNodes, the HDFS components that
   manage file system metadata. Supports high availability (HA) via Quorum
   Journal Manager (QJM).

 - `hdfs-datanode-k8s`: installs DataNodes, which are responsible for
   storing file data.

 - `hdfs-config-k8s`: a configmap containing the HDFS configuration.

 - `zookeeper` (from
   https://kubernetes-charts-incubator.storage.googleapis.com): installs
   ZooKeeper, used to manage NameNode failover. By default, the chart runs
   three ZooKeeper servers.

 - `hdfs-journalnode-k8s`: installs JournalNodes, which ensure that file
   system metadata are properly shared among the NameNodes. By default, the
   chart launches three JournalNode servers.

 - `hdfs-client-k8s`: a pod configured to run Hadoop client commands.

 - `hdfs-krb5-k8s`: a size-1 StatefulSet for launching a Kerberos server,
   which can be used to run HDFS in secure mode. Disabled by default.

 - `hdfs-simple-namenode-k8s`: runs a simple, non-HA HDFS setup (i.e., with a
   single NameNode daemon, no ZooKeeper and no JournalNode). Does not support
   Kerberos. Disabled by default.


# Usage

## Basic

Build the main chart:

```
  $ helm repo add incubator \
      https://kubernetes-charts-incubator.storage.googleapis.com/
  $ helm dependency build charts/hdfs-k8s
```

ZooKeeper, JournalNode and NameNode pods need persistent volumes for storing
metadata. By default, the helm charts do not set the storage class name for
dynamically provisioned volumes, nor do they use selectors for static
persistent volumes. This means they will rely on a default storage class
provisioner for dynamic volumes. Or, if your cluster has statically
provisioned volumes, the chart will match existing volumes entirely based on
the size requirements. To override this default behavior, you can specify
storage volume classes for dynamic volumes, or volume selectors for static
volumes. See the `values.yaml` file for details.

Launch the main chart. The chart release name (e.g., `my-hdfs`), will be the
prefix of the K8s resource names:

```
  $ helm install -n my-hdfs charts/hdfs-k8s
```

Wait for all pods to be ready (some may need to restart a few times).

```
  $ kubectl get pod -l release=my-hdfs

  NAME                             READY     STATUS    RESTARTS   AGE
  my-hdfs-client-c749d9f8f-d5pvk   1/1       Running   0          2m
  my-hdfs-datanode-o7jia           1/1       Running   3          2m
  my-hdfs-datanode-p5kch           1/1       Running   3          2m
  my-hdfs-datanode-r3kjo           1/1       Running   3          2m
  my-hdfs-journalnode-0            1/1       Running   0          2m
  my-hdfs-journalnode-1            1/1       Running   0          2m
  my-hdfs-journalnode-2            1/1       Running   0          1m
  my-hdfs-namenode-0               1/1       Running   3          2m
  my-hdfs-namenode-1               1/1       Running   3          2m
  my-hdfs-zookeeper-0              1/1       Running   0          2m
  my-hdfs-zookeeper-1              1/1       Running   0          2m
  my-hdfs-zookeeper-2              1/1       Running   0          2m
```

By default, NameNodes and DataNodes use `hostNetwork`, so they can see each
other's physical IP and preserve data locality. This can also be changed in
the values file.

Run a few checks on the client pod:

```
  $ _CLIENT=$(kubectl get pods -l app=hdfs-client,release=my-hdfs -o name | \
      cut -d / -f 2)
  $ kubectl exec $_CLIENT -- hdfs dfsadmin -report
  $ kubectl exec $_CLIENT -- hdfs haadmin -getServiceState nn0
  $ kubectl exec $_CLIENT -- hdfs haadmin -getServiceState nn1
  $ kubectl exec $_CLIENT -- hadoop fs -rm -r -f /tmp
  $ kubectl exec $_CLIENT -- hadoop fs -mkdir /tmp
  $ kubectl exec $_CLIENT -- sh -c \
    "(head -c 100M < /dev/urandom > /tmp/random-100M)"
  $ kubectl exec $_CLIENT -- hadoop fs -copyFromLocal /tmp/random-100M /tmp
```

## Kerberos

Kerberos can be enabled by setting a few related options:

```
  $ helm install -n my-hdfs charts/hdfs-k8s \
    --set global.kerberosEnabled=true \
    --set global.kerberosRealm=MYCOMPANY.COM \
    --set tags.kerberos=true
```

This will launch all charts, including the Kerberos server. However, HDFS
daemons will be blocked until Kerberos principals are created. First, create a
configmap containing the common Kerberos config file:

```
  _MY_DIR=~/krb5
  mkdir -p $_MY_DIR
  _KDC=$(kubectl get pod -l app=hdfs-krb5,release=my-hdfs --no-headers \
      -o name | cut -d / -f 2)
  _run kubectl cp $_KDC:/etc/krb5.conf $_MY_DIR/tmp/krb5.conf
  _run kubectl create configmap my-hdfs-krb5-config \
    --from-file=$_MY_DIR/tmp/krb5.conf
```

Then create the service principals and passwords. Kerberos requires service
principals to be host-specific. Some HDFS daemons are associated with the
physical host names of cluster nodes, say `kube-n1.mycompany.com`, while
others are associated with virtual service names, such as
`my-hdfs-namenode-0.my-hdfs-namenode.default.svc.cluster.local`. You can get
the list of these host names with something like the following:

```
  $ _HOSTS=$(kubectl get nodes \
    -o=jsonpath='{.items[*].status.addresses[?(@.type == "Hostname")].address}')
  $ _HOSTS+=$(kubectl describe configmap my-hdfs-config | \
      grep -A 1 -e dfs.namenode.rpc-address.hdfs-k8s \
          -e dfs.namenode.shared.edits.dir |  
      grep "<value>" |
      sed -e "s/<value>//" \
          -e "s/<\/value>//" \
          -e "s/:8020//" \
          -e "s/qjournal:\/\///" \
          -e "s/:8485;/ /g" \
          -e "s/:8485\/hdfs-k8s//")
```

Then generate per-host principal accounts and keytab files:

```
  $ _SECRET_CMD="kubectl create secret generic my-hdfs-krb5-keytabs"
  $ for _HOST in $_HOSTS; do
      kubectl exec $_KDC -- kadmin.local -q \
        "addprinc -randkey hdfs/$_HOST@MYCOMPANY.COM"
      kubectl exec $_KDC -- kadmin.local -q \
        "addprinc -randkey HTTP/$_HOST@MYCOMPANY.COM"
      kubectl exec $_KDC -- kadmin.local -q \
        "ktadd -norandkey -k /tmp/$_HOST.keytab hdfs/$_HOST@MYCOMPANY.COM HTTP/$_HOST@MYCOMPANY.COM"
      kubectl cp $_KDC:/tmp/$_HOST.keytab $_MY_DIR/tmp/$_HOST.keytab
      _SECRET_CMD+=" --from-file=$_MY_DIR/tmp/$_HOST.keytab"
    done
  $ $_SECRET_CMD
```

This will unblock all HDFS daemon pods. Wait until they become ready. Finally,
test the setup:

```
  $ _NN0=$(kubectl get pods -l app=hdfs-namenode,release=my-hdfs -o name | \
      head -1 | cut -d / -f 2)
  $ kubectl exec $_NN0 -- sh -c "(apt install -y krb5-user > /dev/null)"
  $ kubectl exec $_NN0 -- kinit -kt /etc/security/hdfs.keytab \
      hdfs/my-hdfs-namenode-0.my-hdfs-namenode.default.svc.cluster.local@MYCOMPANY.COM
  $ kubectl exec $_NN0 -- hdfs dfsadmin -report
  $ kubectl exec $_NN0 -- hdfs haadmin -getServiceState nn0
  $ kubectl exec $_NN0 -- hdfs haadmin -getServiceState nn1
  $ kubectl exec $_NN0 -- hadoop fs -rm -r -f /tmp
  $ kubectl exec $_NN0 -- hadoop fs -mkdir /tmp
  $ kubectl exec $_NN0 -- hadoop fs -chmod 0777 /tmp
  $ kubectl exec $_KDC -- kadmin.local -q \
      "addprinc -randkey user1@MYCOMPANY.COM"
  $ kubectl exec $_KDC -- kadmin.local -q \
      "ktadd -norandkey -k /tmp/user1.keytab user1@MYCOMPANY.COM"
  $ kubectl cp $_KDC:/tmp/user1.keytab $_MY_DIR/tmp/user1.keytab
  $ kubectl cp $_MY_DIR/tmp/user1.keytab $_CLIENT:/tmp/user1.keytab
  $ kubectl exec $_CLIENT -- sh -c "(apt install -y krb5-user > /dev/null)"
  $ kubectl exec $_CLIENT -- kinit -kt /tmp/user1.keytab user1@MYCOMPANY.COM
  $ kubectl exec $_CLIENT -- sh -c \
      "(head -c 100M < /dev/urandom > /tmp/random-100M)"
  $ kubectl exec $_CLIENT -- hadoop fs -ls /
  $ kubectl exec $_CLIENT -- hadoop fs -copyFromLocal /tmp/random-100M /tmp
```

## Advanced options

### Setting hostPath volume locations for DataNodes

Set `global.dataNodeHostPath` to override the default data storage directories
for DataNodes. Note that you can use a list for multiple disks:

```
  $ helm install -n my-hdfs charts/hdfs-k8s \
      --set "global.dataNodeHostPath={/scratch0/hdfs-data,/scratch1/hdfs-data}"
```

### Using an existing ZooKeeper quorum

By default, `hdfs-k8s` runs a ZooKeeper chart from
https://kubernetes-charts-incubator.storage.googleapis.com. If your K8s
cluster already has a ZooKeeper quorum, you can configure `hdfs-k8s` to use
that instead. For instance:

```
  $helm install -n my-hdfs charts/hdfs-k8s \
    --set condition.subchart.zookeeper=false \
    --set global.zookeeperQuorumOverride=zk-0.zk-svc.default.svc.cluster.local:2181,zk-1.zk-svc.default.svc.cluster.local:2181,zk-2.zk-svc.default.svc.cluster.local:2181
```

### Pinning NameNodes to specific K8s cluster nodes

Optionally, you can attach labels to some of your k8s cluster nodes so that
NameNodes will always run on those nodes. This allows to provide an HDFS
client outside the Kubernetes cluster with stable NameNode IP addresses.

```
  $ kubectl label nodes YOUR-HOST-1 hdfs-namenode-selector=hdfs-namenode
  $ kubectl label nodes YOUR-HOST-2 hdfs-namenode-selector=hdfs-namenode
```

Add the `nodeSelector` option to the helm chart command:

```
  $ helm install -n my-hdfs charts/hdfs-k8s \
     --set hdfs-namenode-k8s.nodeSelector.hdfs-namenode-selector=hdfs-namenode \
     ...
```

### Excluding DataNodes from some K8s cluster nodes

To prevent some K8s cluster nodes from being the targets of a DataNode
deployment, label them with `hdfs-datanode-exclude`:

```
  $ kubectl label node YOUR-CLUSTER-NODE hdfs-datanode-exclude=yes
```

### Launching a simple (non-HA) HDFS cluster

This is the simplest possible setup: one NameNode, no ZooKeepers and no
JournalNodes:

```
  $ helm install -n my-hdfs charts/hdfs-k8s \
      --set tags.ha=false \
      --set tags.simple=true \
      --set global.namenodeHAEnabled=false
```

### Allowing access from outside the Kubernetes cluster

This is currently only supported with simple (non-HA) configurations.

Set properties in `hdfsSite` to configure data nodes to use ports appropriate
for your cloud security group/firewall configuration.

```
    hdfs-config-k8s:
      customHadoopConfig:
         hdfsSite:
           dfs.datanode.ipc.address: "0.0.0.0:32997"
           dfs.datanode.address: "0.0.0.0:32998"
           dfs.datanode.http.address: "0.0.0.0:32999"
```

Configure ports for NodePort services to expose for namenode:

```
  global:
    externalNameNodeHttpPort: 30987
    externalNameNodePort: 30820
```

Finally, enabled the node port service in the hdfs-simple-namenode-k8s chart:

```
    hdfs-simple-namenode-k8s:
      nodePortSvc:
        enabled: true
```

# Security

## K8s secret containing Kerberos keytab files

The Kerberos setup creates a K8s secret containing all the keytab files of HDFS
daemon service principals. This will be mounted onto HDFS daemon pods. You may
want to restrict access to this secret using k8s
[RBAC](https://kubernetes.io/docs/admin/authorization/rbac/).

## hostPath volumes

DataNode daemons run on every cluster node. They also mount k8s `hostPath`
local disk volumes.  You may want to restrict `hostPath` access via pod
security policies. See the [PSP RBAC Example](https://github.com/kubernetes/examples/blob/master/staging/podsecuritypolicy/rbac/README.md).
