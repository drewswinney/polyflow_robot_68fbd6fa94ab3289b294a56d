{ config, pkgs, ros-pkgs, lib, ... }:

let
  user      = "admin";
  password  = "password";
  hostname  = "68fbd6fa94ab3289b294a56d";                     # replace if you template later
  repoName  = "polyflow_robot_${hostname}";
  homeDir   = "/home/${user}";
  wsDir     = "${homeDir}/${repoName}/workspace";

  # Use ROS's Python site-packages and bake in PyYAML
  rosPy     = ros-pkgs.python3;
  rosPyWith = rosPy.withPackages (ps: with ps; [
                pyyaml
                osrf-pycommon
                empy
                catkin-pkg
                lark
              ]);

  # Wrapper that prepares env and launches your ROS package
  webrtcLauncher = pkgs.writeShellScript "webrtc-launch.sh" ''
    #!/usr/bin/env bash
    set -eo pipefail

    # Prepend ROS launch stack (attributes use hyphens, not underscores)
    export PYTHONPATH="\
    ${ros-pkgs.rosPackages.humble.ros2cli}/${pkgs.python3.sitePackages}:\
    ${ros-pkgs.rosPackages.humble.ros2launch}/${pkgs.python3.sitePackages}:\
    ${ros-pkgs.rosPackages.humble.ros2pkg}/${pkgs.python3.sitePackages}:\
    ${ros-pkgs.rosPackages.humble.launch}/${pkgs.python3.sitePackages}:\
    ${ros-pkgs.rosPackages.humble.launch-ros}/${pkgs.python3.sitePackages}:\
    ${ros-pkgs.rosPackages.humble.ament-index-python}/${pkgs.python3.sitePackages}:\
    ${ros-pkgs.rosPackages.humble.ros-base}/${pkgs.python3.sitePackages}:\
    ''${PYTHONPATH:-}"

    # Keep ROS (Nix) Python packages visible, incl. PyYAML
    export PYTHONPATH="${rosPyWith}/${pkgs.python3.sitePackages}:$PYTHONPATH"

    export AMENT_PREFIX_PATH="\
    ${ros-pkgs.rosPackages.humble.ros2launch}:\
    ${ros-pkgs.rosPackages.humble.launch}:\
    ${ros-pkgs.rosPackages.humble.launch-ros}:\
    ${ros-pkgs.rosPackages.humble.ros-base}:\
    $AMENT_PREFIX_PATH"

    # Sanity: ensure PyYAML is importable with ROS's python
    ${ros-pkgs.python3}/bin/python3 - <<'PY' || { echo "[webrtc] PyYAML missing" >&2; exit 1; }
    import yaml, sys
    print("PyYAML OK:", yaml.__version__, "from", getattr(yaml, "__file__", None))
    PY

    # Source colcon overlay; allow unset vars during env hook evaluation
    if [ -f "${wsDir}/install/local_setup.sh" ]; then
      echo "[webrtc] Sourcing ${wsDir}/install/local_setup.sh"
      set +u
      . "${wsDir}/install/local_setup.sh"
      set -u || true
    else
      echo "[webrtc] Missing ${wsDir}/install/local_setup.sh; did build succeed?" >&2
      exit 1
    fi

    echo "[webrtc] Launching…"
    exec ${ros-pkgs.rosPackages.humble.ros2cli}/bin/ros2 launch webrtc launch/webrtc.launch.py
  '';
in
{
  ################################################################################
  # Hardware / boot
  ################################################################################
  nixpkgs.overlays = [
    (final: super: {
      makeModulesClosure = x: super.makeModulesClosure (x // { allowMissing = true; });
    })
  ];

  imports = [
    "${builtins.fetchGit {
      url = "https://github.com/NixOS/nixos-hardware.git";
      rev = "26ed7a0d4b8741fe1ef1ee6fa64453ca056ce113";
    }}/raspberry-pi/4"
  ];

  boot = {
    kernelPackages = ros-pkgs.linuxKernel.packages.linux_rpi4;
    initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" ];
    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
    };
  };

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "noatime" ];
  };

  ################################################################################
  # System basics
  ################################################################################
  system.autoUpgrade.flags = [ "--max-jobs" "1" "--cores" "1" ];

  networking = {
    hostName = hostname;
    networkmanager.enable = true;
    nftables.enable = true;
  };

  services.openssh.enable = true;
  services.timesyncd.enable = true;
  services.timesyncd.servers = [ "pool.ntp.org" ];
  systemd.additionalUpstreamSystemUnits = [ "systemd-time-wait-sync.service" ];
  systemd.services.systemd-time-wait-sync.wantedBy = [ "multi-user.target" ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  hardware.enableRedistributableFirmware = true;
  system.stateVersion = "23.11";

  # Keep a copy of this config on target (optional)
  environment.etc."nixos/configuration.nix" = {
    source = ./configuration.nix;
    mode = "0644";
  };

  ################################################################################
  # Users
  ################################################################################
  users.mutableUsers = false;
  users.users.${user} = {
    isNormalUser = true;
    password = password;
    extraGroups = [ "wheel" ];
    home = homeDir;
  };
  security.sudo.wheelNeedsPassword = false;

  ################################################################################
  # Packages present in the image
  ################################################################################
  environment.systemPackages = with ros-pkgs; with rosPackages.humble; [
    # Tools
    pkgs.git
    pkgs.colcon
    pkgs.python3

    # ROS CLI + launch stack
    ros2cli
    ros2launch
    ros2pkg
    launch
    launch-ros
    ros-base
    ament-index-python

    rosPyWith
  ];

  ################################################################################
  # Services
  ################################################################################

  # 1: Setup: clone/pull and colcon build
  systemd.services.polyflow-setup = {
    description = "Clone/update Polyflow robot repo and colcon build";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "time-sync.target" ];
    wants = [ "network-online.target" "time-sync.target" ];

    # PATH for runtime build tools + ros2 (nice to have)
    path =
      (with pkgs; [ git colcon python3 ]) ++
      (with ros-pkgs.rosPackages.humble; [ ros2cli ros2launch launch launch-ros ros-base ]);

    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = "users";
      WorkingDirectory = homeDir;
      StateDirectory = "polyflow";
      StandardOutput = "journal";
      StandardError  = "journal";
    };

    script = ''
      set -eo pipefail
      export HOME=${homeDir}

      if [ -d "${homeDir}/${repoName}" ]; then
        echo "[setup] Repo exists; pulling latest…"
        cd "${homeDir}/${repoName}"
        git pull --ff-only
      else
        echo "[setup] Cloning repo…"
        git config --global --unset https.proxy || true
        git clone "https://github.com/drewswinney/${repoName}.git" "${homeDir}/${repoName}"
        chown -R ${user}:users "${homeDir}/${repoName}"
      fi

      echo "[setup] Building with colcon…"
      cd "${wsDir}"
      colcon build
      echo "[setup] Done."
    '';
  };

  # 2: Runtime: run your launch file via ros2 launch
  systemd.services.polyflow-webrtc = {
    description = "Run Polyflow WebRTC launch with ros2 launch";
    wantedBy = [ "multi-user.target" ];
    after    = [ "polyflow-setup.service" "network-online.target" ];
    wants    = [ "polyflow-setup.service" "network-online.target" ];

    # PATH includes git/colcon/python (if you need them at runtime) + ROS tools
    path =
      (with pkgs; [ git colcon python3 ]) ++
      (with ros-pkgs.rosPackages.humble; [ ros2cli ros2launch ros2pkg launch launch-ros ament-index-python ros-base ]);

    environment = {
      ROS_DOMAIN_ID = "0";
      LANG = "en_US.UTF-8";
      LC_ALL = "en_US.UTF-8";
    };

    serviceConfig = {
      User             = user;
      Group            = "users";
      WorkingDirectory = wsDir;
      StateDirectory   = "polyflow";
      StandardOutput   = "journal";
      StandardError    = "journal";
      Restart          = "always";
      RestartSec       = "3s";
      ExecStart        = webrtcLauncher;
    };
  };
}
