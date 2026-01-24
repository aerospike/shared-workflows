# Java Hello World (Sample App)

Minimal Java sample used by shared-workflows examples and tests. Builds an
executable JAR plus a versioned POM for Maven-style uploads.

## Build

```sh
./build.sh
```

You can override the version:

```sh
./build.sh -Drevision=1.2.3
```

## Outputs

Artifacts are written to `build/`:

- `java-hello-world-<version>.jar`
- `java-hello-world-<version>.pom`

## Run

```sh
java -jar build/java-hello-world-<version>.jar
```
