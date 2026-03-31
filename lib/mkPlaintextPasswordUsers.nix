{ lib }:
let
  hasValue = value: value != null && value != "";
in
{
  mkOptions =
    {
      extraOptions ? { },
      passwordDescription ? "Plaintext password (simple, not recommended).",
      passwordFileDescription ? "Path to a file containing the plaintext password.",
      passwordSecretDescription ? "Name of a sops secret containing the plaintext password.",
    }:
    extraOptions
    // {
      password = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = passwordDescription;
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = passwordFileDescription;
      };

      passwordSecret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = passwordSecretDescription;
      };
    };

  mkAssertions =
    {
      config,
      users,
      usernamePattern ? null,
      usernameMessage ? null,
      passwordSourceMessage,
      passwordSecretMessage,
      extraAssertions ? (_: _: [ ]),
    }:
    lib.flatten (
      lib.mapAttrsToList
        (uname: u:
          let
            chosen = lib.filter (x: x) [
              (u.password != null)
              (u.passwordFile != null)
              (u.passwordSecret != null)
            ];
          in
          (lib.optional (usernamePattern != null) {
            assertion = builtins.match usernamePattern uname != null;
            message =
              if usernameMessage != null then
                usernameMessage uname
              else
                "Invalid username: ${uname}";
          })
          ++ [
            {
              assertion = (builtins.length chosen) == 1;
              message = passwordSourceMessage uname;
            }
            {
              assertion = u.passwordSecret == null || lib.hasAttrByPath [ "sops" "secrets" u.passwordSecret ] config;
              message = passwordSecretMessage uname;
            }
          ]
          ++ extraAssertions uname u)
        users
    );

  sanitizeForRestart =
    {
      users,
      inheritFields ? [ ],
    }:
    lib.mapAttrs
      (_: userCfg:
        (lib.genAttrs inheritFields (field: userCfg.${field}))
        // {
          password =
            if userCfg.password == null then
              null
            else
              builtins.hashString "sha256" userCfg.password;
          passwordFile =
            if userCfg.passwordFile == null then
              null
            else
              toString userCfg.passwordFile;
        })
      users;

  inherit hasValue;
}
