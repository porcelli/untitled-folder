#!/bin/bash

export VERSION=10.0.0
# Function to extract value from JSON response
extract_json_value() {
    local json="$1"
    local key="$2"
    echo "$json" | grep -o "\"$key\":[^,}]*" | cut -d':' -f2- | tr -d '"' | tr -d ' '
}

# Function to setup registry credentials
setup_registry_credentials() {
    local namespace=$1
    echo "Setting up registry credentials in namespace: $namespace"

    local token
    token=$(oc whoami -t)
    if [ -z "$token" ]; then
        echo "Failed to get OpenShift token. Please ensure you're logged in."
        exit 1
    fi

    echo "Logging into OpenShift registry..."
    oc registry login || true

    if oc get secret registry-credentials >/dev/null 2>&1; then
        echo "Registry credentials secret already exists, updating..."
        oc delete secret registry-credentials
    else
        echo "Creating new registry credentials secret..."
    fi

    oc create secret docker-registry registry-credentials \
        --docker-server=image-registry.openshift-image-registry.svc:5000 \
        --docker-username=$(oc whoami) \
        --docker-password=${token} || true

    if ! oc get sa default -o jsonpath='{.imagePullSecrets[*].name}' | grep -q "registry-credentials"; then
        echo "Linking registry-credentials secret to default service account..."
        oc secrets link default registry-credentials --for=pull
    else
        echo "Secret already linked to default service account"
    fi
}

# Function to get Keycloak access token
get_token() {
    echo "Attempting to get token from: https://${KEYCLOAK_BASE_URL}/auth/realms/master/protocol/openid-connect/token"

    local token_response
    token_response=$(curl -s -k -X POST "https://${KEYCLOAK_BASE_URL}/auth/realms/master/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "username=${ADMIN_USERNAME}" \
      -d "password=${ADMIN_PASSWORD}" \
      -d "grant_type=password" \
      -d "client_id=admin-cli")

    TOKEN=$(extract_json_value "$token_response" "access_token")

    if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
        echo "Failed to obtain access token. Response:"
        echo "$token_response"
        exit 1
    fi

    echo "Successfully obtained access token"
}

# Function to check if realm exists and create if needed
setup_keycloak_realm() {
    local realm="$1"
    echo "Checking if realm $realm exists..."

    local realm_check
    realm_check=$(curl -s -k -X GET "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${realm}" \
      -H "Authorization: Bearer ${TOKEN}")

    if echo "$realm_check" | grep -q "error"; then
        echo "Creating realm $realm..."
        curl -s -k -X POST "https://${KEYCLOAK_BASE_URL}/auth/admin/realms" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d '{
                "realm": "'"${realm}"'",
                "enabled": true,
                "sslRequired": "external",
                "registrationAllowed": false,
                "loginWithEmailAllowed": true,
                "duplicateEmailsAllowed": false,
                "resetPasswordAllowed": true,
                "editUsernameAllowed": false,
                "bruteForceProtected": true
            }'
        echo "Realm created successfully"
    else
        echo "Realm $realm already exists"
    fi
}

# Function to create or update client
setup_client() {
    local realm="$1"
    local client_id="$2"
    local redirect_uri="$3"
    local is_public="${4:-true}"
    local client_secret="${5:-}"

    echo "Setting up client $client_id..."

    # Check if client exists
    local clients_response
    clients_response=$(curl -s -k -X GET "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${realm}/clients" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json")

    local client_internal_id
    client_internal_id=$(echo "$clients_response" | grep -o "{[^}]*\"clientId\":\"$client_id\"[^}]*}" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)

    local payload='{
        "clientId": "'"${client_id}"'",
        "enabled": true,
        "publicClient": '"${is_public}"',
        "redirectUris": ["'"${redirect_uri}"'"],
        "webOrigins": ["+"]'

    if [ "$is_public" = "false" ] && [ -n "$client_secret" ]; then
        payload="${payload}"',"secret": "'"${client_secret}"'"'
    fi

    payload="${payload}"'}'

    if [ -z "$client_internal_id" ]; then
        echo "Creating new client $client_id..."
        curl -s -k -X POST "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${realm}/clients" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$payload"
    else
        echo "Updating existing client $client_id..."
        curl -s -k -X PUT "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${realm}/clients/${client_internal_id}" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$payload"
    fi
}

create_user() {
    local realm="$1"
    local username="jdoe"
    local password="jdoe"
    local firstname="John"
    local lastname="Doe"
    local email="jdoe@example.com"

    echo "Creating user $username in realm $realm..."

    # Create user with direct JSON string (no jq required)
    local user_payload='{
        "username": "'"$username"'",
        "enabled": true,
        "emailVerified": true,
        "firstName": "'"$firstname"'",
        "lastName": "'"$lastname"'",
        "email": "'"$email"'",
        "credentials": [{
            "type": "password",
            "value": "'"$password"'",
            "temporary": false
        }]
    }'

    # Create user
    local create_response
    create_response=$(curl -s -k -X POST "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${realm}/users" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$user_payload")

    if [ -n "$create_response" ] && echo "$create_response" | grep -q "error"; then
        echo "User might already exist, proceeding to get user ID"
    else
        echo "User $username created successfully"
    fi

    # Get user ID using grep and cut instead of jq
    local user_response
    user_response=$(curl -s -k -X GET "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${realm}/users?username=$username" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json")

    local user_id
    user_id=$(echo "$user_response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -z "$user_id" ]; then
        echo "Failed to get user ID for $username"
        return 1
    fi

    echo "Found user ID: $user_id"

    # Array of roles to create and assign
    local roles=("HR" "IT" "user")

    # Create and assign roles
    for role in "${roles[@]}"; do
        echo "Setting up role: $role"

        # Create role if it doesn't exist
        local role_payload='{
            "name": "'"$role"'"
        }'

        curl -s -k -X POST "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${realm}/roles" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$role_payload" || true

        # Get role ID
        local role_response
        role_response=$(curl -s -k -X GET "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${realm}/roles/${role}" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json")

        local role_id
        role_id=$(echo "$role_response" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)

        if [ -n "$role_id" ]; then
            # Assign role to user
            local role_mapping_payload='[{
                "id": "'"$role_id"'",
                "name": "'"$role"'"
            }]'

            curl -s -k -X POST "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${realm}/users/${user_id}/role-mappings/realm" \
                -H "Authorization: Bearer ${TOKEN}" \
                -H "Content-Type: application/json" \
                -d "$role_mapping_payload"

            echo "Role $role assigned to user $username"
        else
            echo "Could not find role ID for $role"
        fi
    done
}

deploy_postgresql() {
    local db_name="$1-postgresql"
    echo "Deploying PostgreSQL database..."

    # Create PostgreSQL secrets
    oc create secret generic postgresql-credentials \
        --from-literal=database-name=kogito \
        --from-literal=database-user=kogito \
        --from-literal=database-password=kogito123 \
        || true

    # Deploy PostgreSQL
    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $db_name
  labels:
    app: $db_name
    app.kubernetes.io/part-of: $APP_PART_OF
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $db_name
  template:
    metadata:
      labels:
        app: $db_name
    spec:
      securityContext:
        runAsNonRoot: true
      containers:
      - name: postgresql
        image: registry.redhat.io/rhel9/postgresql-13:latest
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRESQL_DATABASE
          valueFrom:
            secretKeyRef:
              name: postgresql-credentials
              key: database-name
        - name: POSTGRESQL_USER
          valueFrom:
            secretKeyRef:
              name: postgresql-credentials
              key: database-user
        - name: POSTGRESQL_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgresql-credentials
              key: database-password
        volumeMounts:
        - name: postgresql-data
          mountPath: /var/lib/pgsql/data
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "kogito"]
          initialDelaySeconds: 5
          periodSeconds: 10
          timeoutSeconds: 5
        livenessProbe:
          exec:
            command: ["pg_isready", "-U", "kogito"]
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
      volumes:
      - name: postgresql-data
        persistentVolumeClaim:
          claimName: $db_name-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: $db_name
spec:
  selector:
    app: $db_name
  ports:
  - port: 5432
    targetPort: 5432
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $db_name-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

    # Wait for PostgreSQL to be ready
    echo "Waiting for PostgreSQL to be ready..."
    oc wait --for=condition=available deployment/$db_name --timeout=300s

    # Update environment variables in the main application deployment
    echo "Updating application environment variables for database connection..."
    oc set env deployment/$SERVICE_NAME \
        POSTGRESQL_USER=kogito \
        POSTGRESQL_PASSWORD=kogito123 \
        POSTGRESQL_DATABASE=kogito \
        POSTGRESQL_SERVICE=$db_name

    echo "PostgreSQL deployment completed"
}

# Function to deploy application components
deploy_application() {
    echo "Deploying main application..."
    local all_origins="*"

    # Build and deploy the application with image pull secrets
    mvn clean package \
        -Dquarkus.container-image.build=true \
        -Dquarkus.kubernetes-client.namespace="$NAMESPACE" \
        -Dquarkus.openshift.deployment-kind=Deployment \
        -Dquarkus.kubernetes-client.trust-certs=true \
        -Dquarkus.openshift.deploy=true \
        -Dquarkus.openshift.expose=true \
        -Dquarkus.container-image.group=$NAMESPACE \
        -Dquarkus.application.name="$SERVICE_NAME" \
        -Dquarkus.kubernetes.deployment-target=openshift \
        -Dquarkus.openshift.build-strategy=docker \
        -Dkogito.service.url="https://$SERVICE_NAME-$NAMESPACE.$BASE_URL" \
        -Dkogito.jobs-service.url="https://$SERVICE_NAME-$NAMESPACE.$BASE_URL" \
        -Dkogito.dataindex.http.url="https://$SERVICE_NAME-$NAMESPACE.$BASE_URL" \
        -Dquarkus.openshift.labels.\"app.kubernetes.io/part-of\"=$APP_PART_OF \
        -Dquarkus.openshift.labels.\"app.openshift.io/runtime\"=java \
        -Dquarkus.http.cors=true \
        -Dquarkus.http.cors.origins="$all_origins" \
        -Dquarkus.http.cors.methods="GET,POST,PUT,PATCH,DELETE,OPTIONS" \
        -Dquarkus.http.cors.headers="accept,authorization,content-type,x-requested-with,x-forward-for,content-length,host,origin,referer,Access-Control-Request-Method,Access-Control-Request-Headers" \
        -Dquarkus.http.cors.exposed-headers="Content-Disposition,Content-Type" \
        -Dquarkus.http.cors.access-control-max-age="24H" \
        -Dquarkus.http.cors.access-control-allow-credentials=true \
        -Dquarkus.openshift.env-vars.POSTGRESQL_USER.value="kogito" \
        -Dquarkus.openshift.env-vars.POSTGRESQL_PASSWORD.value="kogito123" \
        -Dquarkus.openshift.env-vars.POSTGRESQL_DATABASE.value="kogito" \
        -Dquarkus.openshift.env-vars.POSTGRESQL_SERVICE.value="$SERVICE_NAME-postgresql" \
        -Dquarkus.openshift.image-pull-secrets=registry-credentials

    # Get the route host
    ROUTE_HOST=$(oc get route "$SERVICE_NAME" -o jsonpath='{.spec.host}')

    # Set environment variables including CORS configuration
    oc set env deployment/"$SERVICE_NAME" \
        KOGITO_SERVICE_URL="https://$ROUTE_HOST" \
        KOGITO_JOBS_SERVICE_URL="https://$ROUTE_HOST" \
        KOGITO_DATAINDEX_HTTP_URL="https://$ROUTE_HOST" \
        QUARKUS_HTTP_CORS=true \
        QUARKUS_HTTP_CORS_ORIGINS="$all_origins" \
        QUARKUS_HTTP_CORS_METHODS="GET,POST,PUT,PATCH,DELETE,OPTIONS" \
        QUARKUS_HTTP_CORS_HEADERS="accept,authorization,content-type,x-requested-with,x-forward-for,content-length,host,origin,referer,Access-Control-Request-Method,Access-Control-Request-Headers" \
        QUARKUS_HTTP_CORS_EXPOSED_HEADERS="Content-Disposition,Content-Type" \
        QUARKUS_HTTP_CORS_ACCESS_CONTROL_MAX_AGE="24H" \
        QUARKUS_HTTP_CORS_ACCESS_CONTROL_ALLOW_CREDENTIALS=true

    # Patch the route for edge TLS termination
    oc patch route "$SERVICE_NAME" -p '{"spec":{"tls":{"termination":"edge"}}}'
}
# Function to deploy task console
deploy_task_console() {
    echo "Deploying task console..."
    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $TASK_CONSOLE_NAME
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/part-of: $APP_PART_OF
    app.openshift.io/runtime: nodejs
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $TASK_CONSOLE_NAME
  template:
    metadata:
      labels:
        app: $TASK_CONSOLE_NAME
    spec:
      imagePullSecrets:
      - name: registry-credentials
      containers:
      - name: task-console
        image: apache/incubator-kie-kogito-task-console:$VERSION
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
        env:
        - name: RUNTIME_TOOLS_TASK_CONSOLE_KOGITO_ENV_MODE
          value: "PROD"
        - name: RUNTIME_TOOLS_TASK_CONSOLE_DATA_INDEX_ENDPOINT
          value: "https://$ROUTE_HOST/graphql"
        - name: KOGITO_CONSOLES_KEYCLOAK_HEALTH_CHECK_URL
          value: "https://${KEYCLOAK_BASE_URL}/auth/realms/$REALM/.well-known/openid-configuration"
        - name: KOGITO_CONSOLES_KEYCLOAK_URL
          value: "https://${KEYCLOAK_BASE_URL}/auth"
        - name: KOGITO_CONSOLES_KEYCLOAK_REALM
          value: "$REALM"
        - name: KOGITO_CONSOLES_KEYCLOAK_CLIENT_ID
          value: "task-console"
---
apiVersion: v1
kind: Service
metadata:
  name: $TASK_CONSOLE_NAME
  namespace: $NAMESPACE
spec:
  selector:
    app: $TASK_CONSOLE_NAME
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: $TASK_CONSOLE_NAME
  namespace: $NAMESPACE
spec:
  to:
    kind: Service
    name: $TASK_CONSOLE_NAME
  port:
    targetPort: 8080
  tls:
    termination: edge
EOF
}

# Function to deploy management console
deploy_management_console() {
    echo "Deploying management console..."
    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $MGMT_CONSOLE_NAME
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/part-of: $APP_PART_OF
    app.openshift.io/runtime: nodejs
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $MGMT_CONSOLE_NAME
  template:
    metadata:
      labels:
        app: $MGMT_CONSOLE_NAME
    spec:
      imagePullSecrets:
      - name: registry-credentials
      containers:
      - name: management-console
        image: apache/incubator-kie-kogito-management-console:$VERSION
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
        env:
        - name: RUNTIME_TOOLS_MANAGEMENT_CONSOLE_KOGITO_ENV_MODE
          value: "DEV"
        - name: RUNTIME_TOOLS_MANAGEMENT_CONSOLE_DATA_INDEX_ENDPOINT
          value: "https://$ROUTE_HOST/graphql"
        - name: KOGITO_CONSOLES_KEYCLOAK_HEALTH_CHECK_URL
          value: "https://${KEYCLOAK_BASE_URL}/auth/realms/$REALM/.well-known/openid-configuration"
        - name: KOGITO_CONSOLES_KEYCLOAK_URL
          value: "https://${KEYCLOAK_BASE_URL}/auth"
        - name: KOGITO_CONSOLES_KEYCLOAK_REALM
          value: "$REALM"
        - name: KOGITO_CONSOLES_KEYCLOAK_CLIENT_ID
          value: "management-console"
        - name: KOGITO_CONSOLES_KEYCLOAK_CLIENT_SECRET
          value: fBd92XRwPlWDt4CSIIDHSxbcB1w0p3jm
---
apiVersion: v1
kind: Service
metadata:
  name: $MGMT_CONSOLE_NAME
  namespace: $NAMESPACE
spec:
  selector:
    app: $MGMT_CONSOLE_NAME
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: $MGMT_CONSOLE_NAME
  namespace: $NAMESPACE
spec:
  to:
    kind: Service
    name: $MGMT_CONSOLE_NAME
  port:
    targetPort: 8080
  tls:
    termination: edge
EOF
}

# Main execution starts here
read -p "Input Namespace: " NAMESPACE

setup_registry_credentials "$NAMESPACE"
oc project "$NAMESPACE"
# Define the service name
SERVICE_NAME="cc-application-approval"


BASE_URL="apps.rm2.thpm.p1.openshiftapps.com"
KEYCLOAK_BASE_URL="keycloak-timothywuthenow-dev.$BASE_URL"
REALM="jbpm-openshift"
ADMIN_USERNAME="admin"

echo "Keycloak Base URL is: $KEYCLOAK_BASE_URL"
read -p "Confirm service name ($SERVICE_NAME)? [Y/n]: " CONFIRM
if [[ $CONFIRM =~ ^[Nn]$ ]]; then
    read -p "Enter new service name: " SERVICE_NAME
fi

# Derive console names
TASK_CONSOLE_NAME="${SERVICE_NAME}-task-console"
MGMT_CONSOLE_NAME="${SERVICE_NAME}-management-console"
# Define the application group name
APP_PART_OF="${SERVICE_NAME}-app"
# Get Keycloak admin password
read -s -p "Enter Keycloak admin password: " ADMIN_PASSWORD
echo

# Configure Keycloak
echo "Configuring Keycloak..."
get_token
setup_keycloak_realm "$REALM"
create_user "$REALM"

# Deploy PostgreSQL
deploy_postgresql "$SERVICE_NAME"

# Setup clients
setup_client "$REALM" "task-console" "https://${TASK_CONSOLE_NAME}-${NAMESPACE}.$BASE_URL/*" true
setup_client "$REALM" "management-console" "https://${MGMT_CONSOLE_NAME}-${NAMESPACE}.$BASE_URL/*" false "fBd92XRwPlWDt4CSIIDHSxbcB1w0p3jm"

# Delete existing deployments if they exist
oc delete deployment "$SERVICE_NAME" --ignore-not-found=true
oc delete deployment "$TASK_CONSOLE_NAME" --ignore-not-found=true
oc delete deployment "$MGMT_CONSOLE_NAME" --ignore-not-found=true

# Deploy all components
deploy_application
deploy_task_console
deploy_management_console

echo "Finalizing deployment"
sleep 45

# Display final URLs
echo "Deployment completed. Application is available at https://$ROUTE_HOST/q/swagger-ui"
echo "Task Console is available at https://$(oc get route "$TASK_CONSOLE_NAME" -o jsonpath='{.spec.host}')"
echo "Management Console is available at https://$(oc get route "$MGMT_CONSOLE_NAME" -o jsonpath='{.spec.host}')"
