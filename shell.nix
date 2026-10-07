{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  packages = with pkgs; [
    git
    kubectl
    minikube
    kubernetes-helm 

    # Only for step 3 (building Scalar)
    # maven
    # jdk

    # Podman aliased to docker
    (writeShellScriptBin "docker" ''exec podman "$@"'')
  ];

  shellHook = ''
    export k8_scalar_dir="$PWD"
    export my_username="$USER"
  '';
}