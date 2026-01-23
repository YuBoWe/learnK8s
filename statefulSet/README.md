### Test
Use the `updateStrategy` field to control the pod update strategy. Testing is as follows:

`kubectl apply -f st-demo-partition.yaml`

Set the `template.spec.containers.image` is `ikubernetes/demoapp:v1.1` , then Use the following command:

`kubectl apply -f st-demo-partition.yaml && kubectl rollout status statefulSet sts-demo`

### Creating Kafka using strimzi

Document: https://strimzi.io/quickstarts/

Use the following command:


Create a namespace called `kafka`:

`kubectl create namespace kafka`

Apply the Strimzi install files, including ClusterRoles, ClusterRoleBindings and some Custom Resource Definitions (CRDs). The CRDs define the schemas used for the custom resources (CRs, such as Kafka, KafkaTopic and so on) you will be using to manage Kafka clusters, topics and users.

`kubectl create -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka`

Follow the deployment of the Strimzi cluster operator:

`kubectl get pod -n kafka `

Create an apache kafka cluster:

`kubectl apply -f https://github.com/strimzi/strimzi-kafka-operator/blob/0.50.0/examples/kafka/kafka-ephemeral.yaml`

Send and receive messages:
> With the cluster running, run a simple producer to send messages to a Kafka topic (the topic is automatically created):

`kubectl -n kafka run kafka-producer -ti --image=quay.io/strimzi/kafka:0.50.0-kafka-4.1.1 --rm=true --restart=Never -- bin/kafka-console-producer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic`

> Once everything is set up correctly, you'll see a prompt where you can type in your messages:

`If you don't see a command prompt, try pressing enter.

>Hello Strimzi!
`
> And to receive them in a different terminal, run:

`kubectl -n kafka run kafka-consumer -ti --image=quay.io/strimzi/kafka:0.50.0-kafka-4.1.1 --rm=true --restart=Never -- bin/kafka-console-consumer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --from-beginning`


Deleting the Apache Kafka cluster:

`kubectl -n kafka delete $(kubectl get strimzi -o name -n kafka) && kubectl delete pvc -l strimzi.io/name=my-cluster-kafka -n kafka`

Deleting the Strimzi cluster operator:

`kubectl -n kafka delete -f strimzi.yaml`

Deleting the Kafka `namespace` field:

`kubectl delete ns kafka`
