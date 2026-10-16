# helm, yq and jq: the tools a repository's check or release build may read whatever its ci-tools.json names, each pinned
# here by its sha256. The ci pipeline inlines this file in its check step and the publish pipeline in build-binaries, before
# files/ci-install-tools.sh and before any script of the repository, and in the list step of mirror, before
# scripts/list-mirror-images.sh, which needs helm and yq alone; scripts/build-contract.test.mjs holds the three steps to it.
# The user of those steps owns /tmp and not /usr/local/bin, so the tools go to a directory of its own, first on PATH.
ci_bin=/tmp/ci-bin
mkdir -p "${ci_bin}"
PATH="${ci_bin}:${PATH}"

# helm 4.3.0, for a check that renders charts.
curl -fsSL -o /tmp/helm.tar.gz https://get.helm.sh/helm-v4.3.0-linux-amd64.tar.gz
echo "86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb  /tmp/helm.tar.gz" | sha256sum -c -
tar -xzf /tmp/helm.tar.gz -C "${ci_bin}" --strip-components=1 linux-amd64/helm

# yq 4.53.6, for a check that reads rendered charts.
curl -fsSL -o "${ci_bin}/yq" https://github.com/mikefarah/yq/releases/download/v4.53.6/yq_linux_amd64
echo "c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385  ${ci_bin}/yq" | sha256sum -c -
chmod +x "${ci_bin}/yq"

# jq 1.8.2, for a check whose suites read JSON (scripts/pipeline-publish.test.sh of hostyour-cloud, test/checks/release_digests_test.dart of ansiwise-cli).
curl -fsSL -o "${ci_bin}/jq" https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-linux-amd64
echo "b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f  ${ci_bin}/jq" | sha256sum -c -
chmod +x "${ci_bin}/jq"
