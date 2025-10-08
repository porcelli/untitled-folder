#!/bin/bash

# Prompt for namespace
read -p "Input Namespace: " NAMESPACE

# Confirm service name
SERVICE_NAME="cc-application-approval"
BASE_URL=apps.sandbox-m2.ll9k.p1.openshiftapps.com
KEYCLOAK_URL=keycloak-$NAMESPACE.$BASE_URL/auth
read -p "Confirm service name ($SERVICE_NAME)? [Y/n]: " CONFIRM
if [[ $CONFIRM =~ ^[Nn]$ ]]; then
    read -p "Enter new service name: " SERVICE_NAME
fi

# Set the OpenShift project
oc project $NAMESPACE

# Build and deploy the application
mvn clean package \
    -Dquarkus.container-image.build=true \
    -Dquarkus.kubernetes-client.namespace=$NAMESPACE \
    -Dquarkus.openshift.deploy=true \
    -Dquarkus.openshift.expose=true \
    -Dquarkus.application.name=$SERVICE_NAME \
    -Dkogito.service.url=https://$SERVICE_NAME-$NAMESPACE.$BASE_URL \
    -Dkogito.jobs-service.url=https://$SERVICE_NAME-$NAMESPACE.$BASE_URL \
    -Dkogito.dataindex.http.url=https://$SERVICE_NAME-$NAMESPACE.$BASE_URL


# Get the route host
ROUTE_HOST=$(oc get route $SERVICE_NAME -o jsonpath='{.spec.host}')

# Set environment variables
oc set env deployment/$SERVICE_NAME \
    KOGITO_SERVICE_URL=https://$ROUTE_HOST \
    KOGITO_JOBS_SERVICE_URL=https://$ROUTE_HOST \
    KOGITO_DATAINDEX_HTTP_URL=https://$ROUTE_HOST

# Patch the route for edge TLS termination
oc patch route $SERVICE_NAME -p '{"spec":{"tls":{"termination":"edge"}}}'

# Deploy Task Console
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: task-console
spec:
  replicas: 1
  selector:
    matchLabels:
      app: task-console
  template:
    metadata:
      labels:
        app: task-console
    spec:
      containers:
      - name: task-console
        image: apache/incubator-kie-kogito-task-console:10.0.0
        ports:
        - containerPort: 8080
        env:
        - name: RUNTIME_TOOLS_TASK_CONSOLE_KOGITO_ENV_MODE
          value: "PROD"
        - name: RUNTIME_TOOLS_TASK_CONSOLE_DATA_INDEX_ENDPOINT
          value: "https://$ROUTE_HOST/graphql"
        - name: KOGITO_CONSOLES_KEYCLOAK_HEALTH_CHECK_URL
          value: "https://$KEYCLOAK_URL/realms/jbpm-openshift/.well-known/openid-configuration"
        - name: KOGITO_CONSOLES_KEYCLOAK_URL
          value: "https://$KEYCLOAK_URL"
        - name: KOGITO_CONSOLES_KEYCLOAK_REALM
          value: "jbpm-openshift"
        - name: KOGITO_CONSOLES_KEYCLOAK_CLIENT_ID
          value: "task-console"
---
apiVersion: v1
kind: Service
metadata:
  name: task-console
spec:
  selector:
    app: task-console
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: task-console
spec:
  to:
    kind: Service
    name: task-console
  port:
    targetPort: 8080
  tls:
    termination: edge
EOF

# Deploy Management Console
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: management-console
spec:
  replicas: 1
  selector:
    matchLabels:
      app: management-console
  template:
    metadata:
      labels:
        app: management-console
    spec:
      containers:
      - name: management-console
        image: apache/incubator-kie-kogito-management-console:10.0.0
        ports:
        - containerPort: 8080
        env:
        - name: RUNTIME_TOOLS_MANAGEMENT_CONSOLE_KOGITO_ENV_MODE
          value: "DEV"
        - name: RUNTIME_TOOLS_MANAGEMENT_CONSOLE_DATA_INDEX_ENDPOINT
          value: "https://$ROUTE_HOST/graphql"
        - name: KOGITO_CONSOLES_KEYCLOAK_HEALTH_CHECK_URL
          value: "https://$KEYCLOAK_URL/realms/jbpm-openshift/.well-known/openid-configuration"
        - name: KOGITO_CONSOLES_KEYCLOAK_URL
          value: "https://$KEYCLOAK_URL"
        - name: KOGITO_CONSOLES_KEYCLOAK_REALM
          value: "jbpm-openshift"
        - name: KOGITO_CONSOLES_KEYCLOAK_CLIENT_ID
          value: "management-console"
        - name: KOGITO_CONSOLES_KEYCLOAK_CLIENT_SECRET
          value: fBd92XRwPlWDt4CSIIDHSxbcB1w0p3jm
---
apiVersion: v1
kind: Service
metadata:
  name: management-console
spec:
  selector:
    app: management-console
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: management-console
spec:
  to:
    kind: Service
    name: management-console
  port:
    targetPort: 8080
  tls:
    termination: edge
EOF

echo "Deployment completed. Application is available at https://$ROUTE_HOST/q/swagger-ui"
echo "Task Console is available at https://$(oc get route task-console -o jsonpath='{.spec.host}')"
echo "Management Console is available at https://$(oc get route management-console -o jsonpath='{.spec.host}')"
