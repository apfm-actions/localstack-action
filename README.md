Localstack Setup Action
=======================

A [GitHub](https://github.com/features/actions) Action to setup
[LocalStack](https://github.com/localstack/localstack) such that it can be used
for a CI/CD target for integration/unit tests during a pull-request.

Example
-------

```
jobs:
  env:
    # Use the example keys allowed by git-secrets.  See <https://github.com/awslabs/git-secrets>
    AWS_ACCESS_KEY_ID: AKIAIOSFODNN7EXAMPLE
    AWS_SECRET_ACCESS_KEY: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
    AWS_DEFAULT_REGION: us-east-1
    LOCALSTACK_SERVICES: cloudwatch,events,ec2,ecs,ecr,iam,sts
  terraform:
    runs-on: ubuntu-latest
    services:
      localstack:
        image: localstack/localstack
        env:
          SERVICES: ${{ env.LOCALSTACK_SERVICES }}
          DEFAULT_REGION: ${{ env.AWS_DEFAULT_REGION }}
        ports:
          - 4566:4566
    steps:
    - name: Localstack Setup
      uses: apfm-actions/localstack-setup-action@v1
      id: localstack
      with:
        services: ${{ env.LOCALSTACK_SERVICES }}

    - run: |
        apt install awscli
        aws --endpoint-url $(( steps.outputs.localstack.endpoint_url }} --region ${{ env.AWS_DEFAULT_REGION }} ec2 describe-vpcs

    - name: Localstack Logs
      if: always()
      uses: apfm-actions/localstack-setup-action@v1
      with:
        cleanup: true
```
