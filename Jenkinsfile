pipeline {
  agent any

  options {
    timestamps()
    ansiColor('xterm')
    timeout(time: 30, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '20'))
    disableConcurrentBuilds()
  }

  environment {
    AWS_REGION      = "${env.AWS_REGION ?: 'us-east-1'}"
    ECR_REPOSITORY  = "${env.ECR_REPOSITORY}"
    ECS_CLUSTER     = "${env.ECS_CLUSTER}"
    ECS_SERVICE     = "${env.ECS_SERVICE}"
    ECS_TASK_FAMILY = "${env.ECS_TASK_FAMILY}"
    CONTAINER_NAME  = 'app'
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        script {
          env.GIT_SHORT_SHA = sh(returnStdout: true, script: 'git rev-parse --short HEAD').trim()
          env.IMAGE_TAG     = "${env.GIT_SHORT_SHA}-${env.BUILD_NUMBER}"
        }
        echo "Building image tag: ${env.IMAGE_TAG}"
      }
    }

    stage('Test') {
      steps {
        dir('app') {
          sh '''
            set -euo pipefail
            docker run --rm \
              -v "$PWD":/app -w /app \
              node:20-alpine \
              sh -c "npm ci --no-audit --no-fund && npm test"
          '''
        }
      }
    }

    stage('Build image') {
      steps {
        dir('app') {
          sh '''
            set -euo pipefail
            docker build \
              --build-arg COMMIT_SHA="$GIT_SHORT_SHA" \
              -t "$ECR_REPOSITORY:$IMAGE_TAG" \
              -t "$ECR_REPOSITORY:latest" \
              .
          '''
        }
      }
    }

    stage('Push to ECR') {
      steps {
        sh '''
          set -euo pipefail
          REGISTRY="${ECR_REPOSITORY%/*}"
          aws ecr get-login-password --region "$AWS_REGION" \
            | docker login --username AWS --password-stdin "$REGISTRY"
          docker push "$ECR_REPOSITORY:$IMAGE_TAG"
          docker push "$ECR_REPOSITORY:latest"
        '''
      }
    }

    stage('Deploy to ECS') {
      steps {
        sh '''
          set -euo pipefail

          aws ecs describe-task-definition \
            --task-definition "$ECS_TASK_FAMILY" \
            --region "$AWS_REGION" \
            --query 'taskDefinition' > taskdef.json

          jq --arg IMAGE "$ECR_REPOSITORY:$IMAGE_TAG" --arg NAME "$CONTAINER_NAME" '
            .containerDefinitions = (.containerDefinitions | map(
              if .name == $NAME then .image = $IMAGE else . end
            ))
            | del(.taskDefinitionArn, .revision, .status, .requiresAttributes,
                  .compatibilities, .registeredAt, .registeredBy, .deregisteredAt)
          ' taskdef.json > taskdef.new.json

          NEW_TD_ARN=$(aws ecs register-task-definition \
            --cli-input-json file://taskdef.new.json \
            --region "$AWS_REGION" \
            --query 'taskDefinition.taskDefinitionArn' --output text)

          echo "Registered: $NEW_TD_ARN"

          aws ecs update-service \
            --cluster "$ECS_CLUSTER" \
            --service "$ECS_SERVICE" \
            --task-definition "$NEW_TD_ARN" \
            --region "$AWS_REGION" > /dev/null

          aws ecs wait services-stable \
            --cluster "$ECS_CLUSTER" \
            --services "$ECS_SERVICE" \
            --region "$AWS_REGION"

          echo "Deployment stable."
        '''
      }
    }
  }

  post {
    success {
      echo "Deployed ${env.IMAGE_TAG} to ${env.ECS_SERVICE}"
    }
    failure {
      echo "Pipeline failed. ECS service was not updated past the last successful deploy."
    }
    always {
      sh 'docker image prune -f --filter "until=24h" || true'
    }
  }
}
