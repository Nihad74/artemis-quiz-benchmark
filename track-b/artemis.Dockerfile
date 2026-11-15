# Track B server image: one Artemis server WAR on one pinned JDK.
#
# All compared commits run on the same base image and the same JVM flags, so a runtime difference cannot come from a
# different JDK patch release or a different Dockerfile of that commit. The WAR is built without the Angular client
# (`./gradlew -Pprod -Pwar bootWar -x webapp`), because the load test calls only the REST API; the Dockerfiles of the
# commits refuse such a WAR. Build context: the folder that contains the WAR (see build-image.sh).

# The JDK of the JSON candidate 8325896e0b4 (deployment/docker/artemis/Dockerfile); the multi-arch index digest.
FROM docker.io/library/eclipse-temurin:25.0.4.1_1-jdk@sha256:3ab7fc8d0b4ade8fef96903fb36767c1dbb4fd1535dcfad85b59c17afbbb5857

# wget: health check; graphviz and locales: as in the Artemis image.
RUN apt-get update && apt-get install -y --no-install-recommends locales graphviz wget \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen
ENV LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 LANGUAGE=en_US.UTF-8

RUN mkdir -p /opt/artemis/config /opt/artemis/data /opt/artemis/public/content \
  && groupadd --gid 1337 artemis && useradd -m --gid 1337 --uid 1337 --shell /bin/bash artemis \
  && chown -R artemis:artemis /opt/artemis
USER artemis:artemis
WORKDIR /opt/artemis

ARG COMMIT
LABEL thesis.commit="${COMMIT}"
COPY --chown=artemis:artemis Artemis.war Artemis.war

EXPOSE 8080

# The flags of the Artemis image, except the heap: a fixed heap (D36), set by the run script.
ENV JAVA_HEAP="-Xms4g -Xmx4g"
ENTRYPOINT ["/bin/sh", "-c", "exec java $JAVA_HEAP -Djdk.tls.ephemeralDHKeySize=2048 -DLC_CTYPE=UTF-8 -Dfile.encoding=UTF-8 -Dsun.jnu.encoding=UTF-8 -Djava.security.egd=file:/dev/./urandom --add-modules java.se --add-exports java.base/jdk.internal.ref=ALL-UNNAMED --add-exports java.naming/com.sun.jndi.ldap=ALL-UNNAMED --add-opens java.base/java.lang=ALL-UNNAMED --add-opens java.base/java.nio=ALL-UNNAMED --add-opens java.base/sun.nio.ch=ALL-UNNAMED --add-opens java.management/sun.management=ALL-UNNAMED --add-opens jdk.management/com.sun.management.internal=ALL-UNNAMED -jar /opt/artemis/Artemis.war"]
