ARG BASH_VERSION=5
FROM bash:${BASH_VERSION}

# Install required packages
RUN apk add --no-cache \
    git \
    bats \
    jq \
    curl

# Configure Git for CI environment
RUN git config --global user.name "CI Test User" && \
    git config --global user.email "test@example.com" && \
    git config --global init.defaultBranch main

# Set working directory
WORKDIR /app

# Default command - use shell to expand the glob pattern
CMD ["/bin/bash", "-c", "bats test/*.bats"]