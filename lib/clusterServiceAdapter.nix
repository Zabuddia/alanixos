{ config, lib }:
let
  clusterCfg = config.alanix.cluster;
in
{
  backupRepoUserGroup =
    if lib.hasAttrByPath [ "users" "users" clusterCfg.backup.repoUser ] config then
      config.users.users.${clusterCfg.backup.repoUser}.group
    else
      "users";

  backupPrepProgressHelpers = ''
    export LC_ALL=C

    emit_prep_step() {
      local step_index="$1"
      local step_total="$2"
      local step_label="$3"

      printf 'ALANIX-PROGRESS STEP %s %s %s\n' "$step_index" "$step_total" "$step_label"
    }

    rsync_prep_step() {
      local step_index="$1"
      local step_total="$2"
      local step_label="$3"
      local source_dir="$4"
      local staged_dir="$5"

      emit_prep_step "$step_index" "$step_total" "$step_label"
      mkdir -p "$staged_dir"
      if [[ -d "$source_dir" ]]; then
        rsync -a --delete --info=progress2,name0 "$source_dir"/ "$staged_dir"/ 2>&1 | tr '\r' '\n'
      fi
    }
  '';

  mkActiveTargetUnits =
    units:
    lib.mkMerge (
      map
        (rawUnit:
          let
            unit =
              if builtins.isString rawUnit then
                {
                  name = rawUnit;
                  start = true;
                }
              else
                rawUnit;
            unitName = unit.name;
            start = unit.start or true;
            collection =
              if lib.hasSuffix ".service" unitName then
                "services"
              else if lib.hasSuffix ".timer" unitName then
                "timers"
              else if lib.hasSuffix ".socket" unitName then
                "sockets"
              else if lib.hasSuffix ".target" unitName then
                "targets"
              else
                throw "Unsupported cluster target unit `${unitName}`.";
            shortName =
              lib.removeSuffix ".target" (
                lib.removeSuffix ".socket" (
                  lib.removeSuffix ".timer" (
                    lib.removeSuffix ".service" unitName
                  )
                )
              );
          in
          lib.setAttrByPath [ "systemd" collection shortName ] (
            {
              partOf = [ "alanix-cluster-active.target" ];
            }
            // lib.optionalAttrs start {
              wantedBy = lib.mkForce [ "alanix-cluster-active.target" ];
            }
          ))
        units
    );
}
