{ config, lib, pkgs, pkgs-unstable, ... }:
let
  cfg = config.alanix.openwebui;
  clusterCfg = cfg.cluster;
  webSearchCfg = cfg.webSearch;
  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };
  passwordUsers = import ../../lib/mkPlaintextPasswordUsers.nix { inherit lib; };

  exposeCfg = cfg.expose;
  inherit (passwordUsers) hasValue;
  mkOpenWebUIBool = value: if value then "True" else "False";
  normalizeLoopbackAddress =
    address:
    if address == "0.0.0.0" then
      "127.0.0.1"
    else if address == "::" then
      "::1"
    else
      address;

  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  baseConfigReady = hasValue cfg.listenAddress && cfg.port != null;

  declaredEmails = lib.mapAttrsToList (_: userCfg: userCfg.email) cfg.users;
  declaredEmailList = lib.concatStringsSep " " declaredEmails;
  declaredEmailLines = lib.concatStringsSep "\n" declaredEmails;

  adminUsers = lib.filterAttrs (_: userCfg: userCfg.admin) cfg.users;
  adminUserNames = builtins.attrNames adminUsers;
  declaredAdminEmails = lib.mapAttrsToList (_: userCfg: userCfg.email) adminUsers;
  declaredAdminEmailLines = lib.concatStringsSep "\n" declaredAdminEmails;

  sanitizeUserKey = name: lib.replaceStrings [ "-" "." "@" "+" ] [ "_" "_" "_" "_" ] name;

  bootstrapAdminName = if adminUserNames == [ ] then null else builtins.head adminUserNames;
  bootstrapAdmin = if bootstrapAdminName == null then null else adminUsers.${bootstrapAdminName};
  bootstrapAdminEmail = if bootstrapAdmin == null then "" else bootstrapAdmin.email;
  bootstrapAdminDisplayName = if bootstrapAdmin == null then "" else bootstrapAdmin.name;
  bootstrapAdminProfileImageUrl = if bootstrapAdmin == null then "/user.png" else bootstrapAdmin.profileImageUrl;
  bootstrapPassVar = if bootstrapAdminName == null then "" else "PASSFILE_" + sanitizeUserKey bootstrapAdminName;

  effectiveRootUrl =
    if cfg.rootUrl == null then
      ""
    else
      lib.removeSuffix "/" cfg.rootUrl;

  derivedSearxngQueryUrl =
    if config.alanix.searxng.enable && config.alanix.searxng.listenAddress != null && config.alanix.searxng.port != null then
      "http://${normalizeLoopbackAddress config.alanix.searxng.listenAddress}:${toString config.alanix.searxng.port}/search?q=<query>&format=json"
    else
      null;

  effectiveSearxngQueryUrl =
    if webSearchCfg.searxngQueryUrl != null then
      webSearchCfg.searxngQueryUrl
    else
      derivedSearxngQueryUrl;

  padStrings = size: values:
    let
      count = builtins.length values;
    in
    if count >= size then
      lib.take size values
    else
      values ++ builtins.genList (_: "") (size - count);

  effectiveOpenAIApiKeys = padStrings (builtins.length cfg.openai.baseUrls) cfg.openai.apiKeys;
  effectiveOpenAIEnabled = cfg.openai.baseUrls != [ ];

  managedEnvironment = {
    WEBUI_AUTH = mkOpenWebUIBool true;
    ENABLE_PASSWORD_AUTH = mkOpenWebUIBool true;
    ENABLE_LOGIN_FORM = mkOpenWebUIBool true;
    ENABLE_INITIAL_ADMIN_SIGNUP = mkOpenWebUIBool true;
    ENABLE_SIGNUP = mkOpenWebUIBool (!cfg.disableRegistration);
    DEFAULT_USER_ROLE = "pending";
    SHOW_ADMIN_DETAILS = mkOpenWebUIBool false;
    WEBUI_URL = effectiveRootUrl;
    ENABLE_OPENAI_API = mkOpenWebUIBool effectiveOpenAIEnabled;
    OPENAI_API_BASE_URLS = lib.concatStringsSep ";" cfg.openai.baseUrls;
    OPENAI_API_KEYS = lib.concatStringsSep ";" effectiveOpenAIApiKeys;
    ENABLE_OLLAMA_API = mkOpenWebUIBool false;
    OLLAMA_BASE_URLS = "";
    ENABLE_WEB_SEARCH = mkOpenWebUIBool webSearchCfg.enable;
    WEB_SEARCH_ENGINE = webSearchCfg.engine;
    WEB_SEARCH_TRUST_ENV = mkOpenWebUIBool webSearchCfg.trustEnv;
    WEB_SEARCH_RESULT_COUNT = toString webSearchCfg.resultCount;
    WEB_SEARCH_CONCURRENT_REQUESTS = toString webSearchCfg.concurrentRequests;
    WEB_LOADER_CONCURRENT_REQUESTS = toString webSearchCfg.loaderConcurrentRequests;
    WEB_SEARCH_DOMAIN_FILTER_LIST = lib.concatStringsSep "," webSearchCfg.domainFilterList;
    BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL = mkOpenWebUIBool webSearchCfg.bypassEmbeddingAndRetrieval;
    BYPASS_WEB_SEARCH_WEB_LOADER = mkOpenWebUIBool webSearchCfg.bypassWebLoader;
    SEARXNG_QUERY_URL = if effectiveSearxngQueryUrl == null then "" else effectiveSearxngQueryUrl;
  };

  bcryptPython = pkgs.python3.withPackages (ps: [ ps.bcrypt ]);

  sanitizedUsersForRestart = passwordUsers.sanitizeForRestart {
    users = cfg.users;
    inheritFields = [
      "admin"
      "email"
      "name"
      "passwordSecret"
      "profileImageUrl"
    ];
  };
in
{
  options.alanix.openwebui = {
    enable = lib.mkEnableOption "Open WebUI (Alanix)";

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/open-webui";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional Open WebUI cluster backup staging directory.";
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage Open WebUI through alanix.cluster";

      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "5m";
      };

      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "15m";
      };
    };

    rootUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional public Open WebUI URL, including http:// or https://.";
    };

    disableRegistration = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether Open WebUI should disallow open signups after the initial bootstrap admin is created.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional environment file passed to services.open-webui for non-store secrets such as DATABASE_URL.";
    };

    pruneUndeclaredUsers = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Delete Open WebUI users that are not present in alanix.openwebui.users.";
    };

    openai = {
      baseUrls = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Explicit OpenAI-compatible API base URLs for Open WebUI, for example a LiteLLM endpoint.";
      };

      apiKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Optional OpenAI-compatible API keys matched positionally with openai.baseUrls.";
      };
    };

    webSearch = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to enable Open WebUI web search.";
      };

      engine = lib.mkOption {
        type = lib.types.str;
        default = "duckduckgo";
        description = "Open WebUI web search engine identifier, for example brave, searxng, or duckduckgo.";
      };

      resultCount = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = "Maximum number of search results Open WebUI should crawl.";
      };

      concurrentRequests = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 0;
        description = "Maximum concurrent requests sent to the search engine provider. Brave free-tier users usually want 1.";
      };

      loaderConcurrentRequests = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = "Maximum concurrent requests used to fetch result pages.";
      };

      trustEnv = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether Open WebUI should honor http_proxy and https_proxy for web search fetching.";
      };

      domainFilterList = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Optional domain filter list passed to Open WebUI web search.";
      };

      bypassEmbeddingAndRetrieval = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether Open WebUI should skip the web-search embedding and retrieval step.";
      };

      bypassWebLoader = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether Open WebUI should skip fetching full page contents and only use snippets.";
      };

      braveApiKeySecret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Optional sops secret containing the Brave Search API key. When set, the
          module exposes it to Open WebUI through a generated environment file and
          also reconciles it into Open WebUI's persistent web-search config.
        '';
      };

      searxngQueryUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Optional SearXNG query URL for Open WebUI, for example
          http://127.0.0.1:8888/search?q=<query>&format=json. When omitted and
          alanix.searxng is enabled locally, the module derives a loopback URL
          automatically.
        '';
      };
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
        options = passwordUsers.mkOptions {
          extraOptions = {
            admin = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };

            email = lib.mkOption {
              type = lib.types.str;
              description = "Email address used to sign in to Open WebUI.";
            };

            name = lib.mkOption {
              type = lib.types.str;
              description = "Display name for the Open WebUI user.";
            };

            profileImageUrl = lib.mkOption {
              type = lib.types.str;
              default = "/user.png";
              description = "Profile image URL passed through to Open WebUI.";
            };
          };
        };
      }));
      default = { };
      description = "Declarative Open WebUI users keyed by a local label; reconciliation matches them by email.";
    };

    expose = serviceExposure.mkOptions {
      serviceName = "openwebui";
      serviceDescription = "Open WebUI";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = cfg.users != { };
            message = "alanix.openwebui: users must not be empty when enable = true.";
          }
          {
            assertion = lib.length declaredAdminEmails > 0;
            message = "alanix.openwebui: at least one declared user must have admin = true.";
          }
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.openwebui.listenAddress must be set when alanix.openwebui.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.openwebui.port must be set when alanix.openwebui.enable = true.";
          }
          {
            assertion = lib.hasPrefix "/" cfg.stateDir;
            message = "alanix.openwebui.stateDir must be an absolute path.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.openwebui.backupDir must be an absolute path when set.";
          }
          {
            assertion = cfg.rootUrl == null || builtins.match "^https?://.+" cfg.rootUrl != null;
            message = "alanix.openwebui.rootUrl must include http:// or https:// when set.";
          }
          {
            assertion = cfg.environmentFile == null || lib.hasPrefix "/" cfg.environmentFile;
            message = "alanix.openwebui.environmentFile must be an absolute path when set.";
          }
          {
            assertion = lib.length declaredEmails == lib.length (lib.unique declaredEmails);
            message = "alanix.openwebui.users.*.email must be unique.";
          }
          {
            assertion = cfg.openai.baseUrls != [ ];
            message = "alanix.openwebui.openai.baseUrls must contain at least one explicit OpenAI-compatible endpoint.";
          }
          {
            assertion = builtins.length cfg.openai.apiKeys <= builtins.length cfg.openai.baseUrls;
            message = "alanix.openwebui.openai.apiKeys must not contain more entries than alanix.openwebui.openai.baseUrls.";
          }
          {
            assertion = !clusterCfg.enable || cfg.backupDir != null;
            message = "alanix.openwebui.cluster.enable requires alanix.openwebui.backupDir.";
          }
          {
            assertion = !webSearchCfg.enable || hasValue webSearchCfg.engine;
            message = "alanix.openwebui.webSearch.engine must be set when alanix.openwebui.webSearch.enable = true.";
          }
          {
            assertion =
              !webSearchCfg.enable
              || webSearchCfg.engine != "searxng"
              || effectiveSearxngQueryUrl != null;
            message = "alanix.openwebui.webSearch.searxngQueryUrl must be set, or alanix.searxng must be enabled locally, when SearXNG web search is enabled.";
          }
          {
            assertion = webSearchCfg.braveApiKeySecret == null || lib.hasAttrByPath [ "sops" "secrets" webSearchCfg.braveApiKeySecret ] config;
            message = "alanix.openwebui.webSearch.braveApiKeySecret must reference a declared sops secret.";
          }
          {
            assertion = !webSearchCfg.enable || webSearchCfg.engine != "brave" || webSearchCfg.braveApiKeySecret != null || cfg.environmentFile != null;
            message = "alanix.openwebui.webSearch.braveApiKeySecret must be set, or alanix.openwebui.environmentFile must provide BRAVE_SEARCH_API_KEY, when Brave web search is enabled.";
          }
          {
            assertion =
              webSearchCfg.searxngQueryUrl == null
              || (builtins.match "^https?://.+" webSearchCfg.searxngQueryUrl != null
                && lib.hasInfix "<query>" webSearchCfg.searxngQueryUrl);
            message = "alanix.openwebui.webSearch.searxngQueryUrl must include http:// or https:// and contain the <query> placeholder.";
          }
        ]
        ++ lib.flatten (
          lib.imap0
            (idx: url: [
              {
                assertion = builtins.match "^https?://.+" url != null;
                message = "alanix.openwebui.openai.baseUrls[${toString idx}] must include http:// or https://.";
              }
            ])
            cfg.openai.baseUrls
        )
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.openwebui.expose";
        }
        ++ passwordUsers.mkAssertions {
          inherit config;
          users = cfg.users;
          usernamePattern = "^[A-Za-z0-9._-]+$";
          usernameMessage = uname: "alanix.openwebui.users.${uname}: local labels may contain only letters, digits, dot, underscore, and hyphen.";
          passwordSourceMessage = uname: "alanix.openwebui.users.${uname}: set exactly one of password, passwordFile, or passwordSecret.";
          passwordSecretMessage = uname: "alanix.openwebui.users.${uname}.passwordSecret must reference a declared sops secret.";
          extraAssertions = uname: u: [
            {
              assertion = hasValue u.email;
              message = "alanix.openwebui.users.${uname}.email must be set.";
            }
            {
              assertion = hasValue u.name;
              message = "alanix.openwebui.users.${uname}.name must be set.";
            }
          ];
        };

      sops.templates."alanix-openwebui-env" = lib.mkIf (webSearchCfg.braveApiKeySecret != null) {
        content = ''
          BRAVE_SEARCH_API_KEY=${config.sops.placeholder.${webSearchCfg.braveApiKeySecret}}
        '';
        owner = "root";
        group = "root";
        mode = "0400";
      };

      services.open-webui = lib.mkIf baseConfigReady {
        enable = true;
        package = pkgs-unstable.open-webui;
        host = cfg.listenAddress;
        port = cfg.port;
        stateDir = cfg.stateDir;
        openFirewall = false;
        environment = managedEnvironment;
        environmentFile = cfg.environmentFile;
      };

      users.groups.open-webui = lib.mkIf clusterCfg.enable { };

      users.users.open-webui = lib.mkIf clusterCfg.enable {
        isSystemUser = true;
        group = "open-webui";
        home = cfg.stateDir;
        createHome = false;
      };

      systemd.services.open-webui.serviceConfig = lib.mkIf baseConfigReady (
        (lib.optionalAttrs clusterCfg.enable {
          DynamicUser = lib.mkForce false;
          User = lib.mkForce "open-webui";
          Group = lib.mkForce "open-webui";
        })
        // {
          EnvironmentFile = lib.mkForce (
            lib.optional (cfg.environmentFile != null) cfg.environmentFile
            ++ lib.optional (webSearchCfg.braveApiKeySecret != null) config.sops.templates."alanix-openwebui-env".path
          );
        }
      );

      systemd.services.open-webui-reconcile = lib.mkIf (cfg.users != { } && baseConfigReady) {
        description = "Reconcile Open WebUI users and managed settings";
        after = [ "open-webui.service" "sops-nix.service" ];
        wants = [ "open-webui.service" "sops-nix.service" ];
        partOf = [ "open-webui.service" ];
        wantedBy = [ "open-webui.service" ];

        serviceConfig = {
          Type = "oneshot";
          SuccessExitStatus = [ "SIGTERM" ];
          User = "root";
          Group = "root";
          RuntimeDirectory = "alanix-openwebui";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
        }
        // lib.optionalAttrs (cfg.environmentFile != null || webSearchCfg.braveApiKeySecret != null) {
          EnvironmentFile =
            lib.optional (cfg.environmentFile != null) cfg.environmentFile
            ++ lib.optional (webSearchCfg.braveApiKeySecret != null) config.sops.templates."alanix-openwebui-env".path;
        };

        environment = managedEnvironment // {
          HOME = cfg.stateDir;
        };

        path = [
          pkgs.coreutils
          pkgs.curl
          pkgs.gawk
          pkgs.gnugrep
          pkgs.jq
          pkgs.openssl
          pkgs.sqlite
          bcryptPython
        ];

        script =
          let
            passfileLines =
              lib.concatStringsSep "\n"
                (lib.mapAttrsToList (uname: u:
                  let
                    var = "PASSFILE_" + sanitizeUserKey uname;
                    runtimePassfile = "$RUNTIME_DIRECTORY/${sanitizeUserKey uname}.pass";
                  in
                  if u.passwordFile != null then
                    ''${var}=${lib.escapeShellArg (toString u.passwordFile)}''
                  else if u.passwordSecret != null then
                    ''${var}=${lib.escapeShellArg config.sops.secrets.${u.passwordSecret}.path}''
                  else
                    ''${var}=${lib.escapeShellArg runtimePassfile}; ensure_runtime_passfile "${"$"}${var}" ${lib.escapeShellArg u.password}''
                ) cfg.users);

            loginDeclaredAdminLines =
              lib.concatStringsSep "\n"
                (lib.mapAttrsToList (uname: u:
                  let
                    var = "PASSFILE_" + sanitizeUserKey uname;
                  in
                  lib.optionalString u.admin ''
                    if token="$(login_with_password ${lib.escapeShellArg u.email} "${"$"}${var}")"; then
                      ACTING_TOKEN="$token"
                      ACTING_EMAIL=${lib.escapeShellArg u.email}
                      return 0
                    fi
                  ''
                ) cfg.users);

            passfileLookupLines =
              lib.concatStringsSep "\n"
                (lib.mapAttrsToList (uname: u:
                  let
                    var = "PASSFILE_" + sanitizeUserKey uname;
                  in
                  ''
                    if [ "$email" = ${lib.escapeShellArg u.email} ]; then
                      printf '%s\n' "${"$"}${var}"
                      return 0
                    fi
                  ''
                ) cfg.users);

            ensureLines =
              lib.concatStringsSep "\n"
                (lib.mapAttrsToList (_: u:
                  ''ensure_user ${lib.escapeShellArg u.email} ${lib.escapeShellArg u.name} ${lib.escapeShellArg u.profileImageUrl} "$(passfile_for_email ${lib.escapeShellArg u.email})" ${if u.admin then "admin" else "user"}''
                ) cfg.users);
          in
          ''
            set -euo pipefail

            BASE_URL=${lib.escapeShellArg "http://${cfg.listenAddress}:${toString cfg.port}"}
            DECLARED_EMAILS=${lib.escapeShellArg declaredEmailList}
            DECLARED_EMAIL_LINES=${lib.escapeShellArg declaredEmailLines}
            DECLARED_ADMIN_EMAIL_LINES=${lib.escapeShellArg declaredAdminEmailLines}
            PRUNE=${if cfg.pruneUndeclaredUsers then "1" else "0"}
            BOOTSTRAP_EMAIL=${lib.escapeShellArg bootstrapAdminEmail}
            BOOTSTRAP_NAME=${lib.escapeShellArg bootstrapAdminDisplayName}
            BOOTSTRAP_PROFILE_IMAGE_URL=${lib.escapeShellArg bootstrapAdminProfileImageUrl}
            BOOTSTRAP_PASSVAR=${lib.escapeShellArg bootstrapPassVar}
            DESIRED_WEBUI_URL=${lib.escapeShellArg effectiveRootUrl}
            DESIRED_ADMIN_EMAIL=${lib.escapeShellArg bootstrapAdminEmail}
            DESIRED_ENABLE_SIGNUP=${if cfg.disableRegistration then "false" else "true"}
            DESIRED_OPENAI_API_BASE_URLS=${lib.escapeShellArg (builtins.toJSON cfg.openai.baseUrls)}
            DESIRED_OPENAI_API_KEYS=${lib.escapeShellArg (builtins.toJSON effectiveOpenAIApiKeys)}
            DESIRED_ENABLE_WEB_SEARCH=${lib.escapeShellArg (builtins.toJSON webSearchCfg.enable)}
            DESIRED_WEB_SEARCH_ENGINE=${lib.escapeShellArg webSearchCfg.engine}
            DESIRED_WEB_SEARCH_TRUST_ENV=${lib.escapeShellArg (builtins.toJSON webSearchCfg.trustEnv)}
            DESIRED_WEB_SEARCH_RESULT_COUNT=${lib.escapeShellArg (builtins.toJSON webSearchCfg.resultCount)}
            DESIRED_WEB_SEARCH_CONCURRENT_REQUESTS=${lib.escapeShellArg (builtins.toJSON webSearchCfg.concurrentRequests)}
            DESIRED_WEB_LOADER_CONCURRENT_REQUESTS=${lib.escapeShellArg (builtins.toJSON webSearchCfg.loaderConcurrentRequests)}
            DESIRED_WEB_SEARCH_DOMAIN_FILTER_LIST=${lib.escapeShellArg (builtins.toJSON webSearchCfg.domainFilterList)}
            DESIRED_BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL=${lib.escapeShellArg (builtins.toJSON webSearchCfg.bypassEmbeddingAndRetrieval)}
            DESIRED_BYPASS_WEB_SEARCH_WEB_LOADER=${lib.escapeShellArg (builtins.toJSON webSearchCfg.bypassWebLoader)}
            DESIRED_BRAVE_SEARCH_API_KEY="''${BRAVE_SEARCH_API_KEY:-}"
            DESIRED_SEARXNG_QUERY_URL=${lib.escapeShellArg (if effectiveSearxngQueryUrl == null then "" else effectiveSearxngQueryUrl)}
            DEFAULT_DATABASE_URL=${lib.escapeShellArg "sqlite:///${cfg.stateDir}/data/webui.db"}

            ensure_runtime_passfile() {
              local path="$1"
              local value="$2"
              umask 077
              printf '%s' "$value" > "$path"
            }

            public_post_json() {
              local path="$1"
              local body="$2"
              curl -sS -f \
                -H 'Content-Type: application/json' \
                -X POST \
                -d "$body" \
                "$BASE_URL$path"
            }

            api_get() {
              local path="$1"
              local token="$2"
              curl -sS -f \
                -H "Authorization: Bearer $token" \
                "$BASE_URL$path"
            }

            api_post_json() {
              local path="$1"
              local body="$2"
              local token="$3"
              curl -sS -f \
                -H 'Content-Type: application/json' \
                -H "Authorization: Bearer $token" \
                -X POST \
                -d "$body" \
                "$BASE_URL$path"
            }

            api_put_json() {
              local path="$1"
              local body="$2"
              local token="$3"
              curl -sS -f \
                -H 'Content-Type: application/json' \
                -H "Authorization: Bearer $token" \
                -X POST \
                -d "$body" \
                "$BASE_URL$path"
            }

            api_delete() {
              local path="$1"
              local token="$2"
              curl -sS -f \
                -H "Authorization: Bearer $token" \
                -X DELETE \
                "$BASE_URL$path"
            }

            wait_for_server() {
              # First boot can spend a couple of minutes running migrations
              # before the HTTP health endpoint comes up.
              local attempts=300

              while [ "$attempts" -gt 0 ]; do
                if curl -sS -f "$BASE_URL/health" >/dev/null 2>&1; then
                  return 0
                fi

                sleep 1
                attempts=$((attempts - 1))
              done

              echo "Timed out waiting for Open WebUI to become ready." >&2
              return 1
            }

            login_with_inline_password() {
              local email="$1"
              local password="$2"
              local payload
              local response

              payload="$(jq -n --arg email "$email" --arg password "$password" '{ email: $email, password: $password }')"
              response="$(public_post_json "/api/v1/auths/signin" "$payload" 2>/dev/null)" || return 1
              printf '%s' "$response" | jq -er '.token'
            }

            login_with_password() {
              local email="$1"
              local passfile="$2"
              local password

              password="$(tr -d '\r\n' < "$passfile")"
              login_with_inline_password "$email" "$password"
            }

            passfile_for_email() {
              local email="$1"

              ${passfileLookupLines}

              return 1
            }

            try_bootstrap_first_admin() {
              local bootstrap_passfile
              local bootstrap_password
              local payload
              local response

              [ -n "$BOOTSTRAP_EMAIL" ] || return 1
              [ -n "$BOOTSTRAP_PASSVAR" ] || return 1

              bootstrap_passfile="''${!BOOTSTRAP_PASSVAR}"
              [ -n "$bootstrap_passfile" ] || return 1
              bootstrap_password="$(tr -d '\r\n' < "$bootstrap_passfile")"

              payload="$(
                jq -n \
                  --arg email "$BOOTSTRAP_EMAIL" \
                  --arg name "$BOOTSTRAP_NAME" \
                  --arg password "$bootstrap_password" \
                  --arg profile_image_url "$BOOTSTRAP_PROFILE_IMAGE_URL" \
                  '{ email: $email, name: $name, password: $password, profile_image_url: $profile_image_url }'
              )"

              response="$(public_post_json "/api/v1/auths/signup" "$payload" 2>/dev/null)" || return 1
              ACTING_TOKEN="$(printf '%s' "$response" | jq -er '.token')" || return 1
              ACTING_EMAIL="$BOOTSTRAP_EMAIL"
            }

            try_declared_admin_logins() {
              local token

              ${loginDeclaredAdminLines}

              return 1
            }

            database_path_from_url() {
              local url="$1"

              case "$url" in
                sqlite:///*)
                  printf '%s\n' "''${url#sqlite:///}"
                  ;;
                *)
                  return 1
                  ;;
              esac
            }

            first_existing_db_email() {
              local db_path="$1"
              sqlite3 "$db_path" "SELECT email FROM user ORDER BY created_at ASC LIMIT 1;"
            }

            sqlite_has_email() {
              local db_path="$1"
              local email="$2"
              sqlite3 "$db_path" "SELECT email FROM user WHERE lower(email) = lower('$email') LIMIT 1;" | grep -Fq .
            }

            pick_recovery_candidate_email() {
              local db_path="$1"
              local email

              while IFS= read -r email; do
                [ -n "$email" ] || continue
                if sqlite_has_email "$db_path" "$email"; then
                  printf '%s\n' "$email"
                  return 0
                fi
              done <<EOF
$DECLARED_ADMIN_EMAIL_LINES
EOF

              while IFS= read -r email; do
                [ -n "$email" ] || continue
                if sqlite_has_email "$db_path" "$email"; then
                  printf '%s\n' "$email"
                  return 0
                fi
              done <<EOF
$DECLARED_EMAIL_LINES
EOF

              first_existing_db_email "$db_path"
            }

            reset_sqlite_password_and_promote_admin() {
              local db_path="$1"
              local email="$2"
              local password="$3"

              ${lib.getExe bcryptPython} - "$db_path" "$email" "$password" <<'PY'
import sqlite3
import sys
import bcrypt

db_path, email, password = sys.argv[1:4]
password_hash = bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")

conn = sqlite3.connect(db_path)
conn.execute("PRAGMA busy_timeout = 5000")
cur = conn.cursor()
cur.execute("UPDATE auth SET password = ? WHERE lower(email) = lower(?)", (password_hash, email))
if cur.rowcount == 0:
    raise SystemExit("No matching auth row for recovery")
cur.execute("UPDATE user SET role = 'admin' WHERE lower(email) = lower(?)", (email,))
if cur.rowcount == 0:
    raise SystemExit("No matching user row for recovery")
conn.commit()
PY
            }

            recover_admin_token_from_sqlite() {
              local database_url
              local db_path
              local candidate
              local recovery_password
              local passfile

              database_url="''${DATABASE_URL:-$DEFAULT_DATABASE_URL}"
              db_path="$(database_path_from_url "$database_url")" || return 1
              [ -f "$db_path" ] || return 1

              candidate="$(pick_recovery_candidate_email "$db_path")"
              [ -n "$candidate" ] || return 1

              if passfile="$(passfile_for_email "$candidate" 2>/dev/null)"; then
                recovery_password="$(tr -d '\r\n' < "$passfile")"
              else
                recovery_password="$(openssl rand -hex 16)"
              fi

              echo "Recovering Open WebUI admin access through sqlite for: $candidate"
              reset_sqlite_password_and_promote_admin "$db_path" "$candidate" "$recovery_password"

              ACTING_TOKEN="$(login_with_inline_password "$candidate" "$recovery_password")" || return 1
              ACTING_EMAIL="$candidate"
            }

            sync_admin_config() {
              local token="$1"
              local current
              local payload

              current="$(api_get "/api/v1/auths/admin/config" "$token")"
              payload="$(
                printf '%s' "$current" | jq \
                  --arg webui_url "$DESIRED_WEBUI_URL" \
                  --arg admin_email "$DESIRED_ADMIN_EMAIL" \
                  --argjson enable_signup "$DESIRED_ENABLE_SIGNUP" \
                  '
                    .SHOW_ADMIN_DETAILS = false
                    | .WEBUI_URL = $webui_url
                    | .ENABLE_SIGNUP = $enable_signup
                    | .DEFAULT_USER_ROLE = "pending"
                    | .ADMIN_EMAIL = (if $admin_email == "" then null else $admin_email end)
                  '
              )"
              api_post_json "/api/v1/auths/admin/config" "$payload" "$token" >/dev/null
            }

            sync_openai_config() {
              local token="$1"
              local current
              local payload

              current="$(api_get "/openai/config" "$token")"
              payload="$(
                printf '%s' "$current" | jq \
                  --argjson base_urls "$DESIRED_OPENAI_API_BASE_URLS" \
                  --argjson api_keys "$DESIRED_OPENAI_API_KEYS" \
                  '
                    .ENABLE_OPENAI_API = true
                    | .OPENAI_API_BASE_URLS = $base_urls
                    | .OPENAI_API_KEYS = $api_keys
                  '
              )"
              api_post_json "/openai/config/update" "$payload" "$token" >/dev/null
            }

            sync_web_search_config() {
              local token="$1"
              local current
              local payload

              current="$(api_get "/api/v1/retrieval/config" "$token")"
              payload="$(
                printf '%s' "$current" | jq \
                  --arg web_search_engine "$DESIRED_WEB_SEARCH_ENGINE" \
                  --arg brave_search_api_key "$DESIRED_BRAVE_SEARCH_API_KEY" \
                  --arg searxng_query_url "$DESIRED_SEARXNG_QUERY_URL" \
                  --argjson enable_web_search "$DESIRED_ENABLE_WEB_SEARCH" \
                  --argjson web_search_trust_env "$DESIRED_WEB_SEARCH_TRUST_ENV" \
                  --argjson web_search_result_count "$DESIRED_WEB_SEARCH_RESULT_COUNT" \
                  --argjson web_search_concurrent_requests "$DESIRED_WEB_SEARCH_CONCURRENT_REQUESTS" \
                  --argjson web_loader_concurrent_requests "$DESIRED_WEB_LOADER_CONCURRENT_REQUESTS" \
                  --argjson web_search_domain_filter_list "$DESIRED_WEB_SEARCH_DOMAIN_FILTER_LIST" \
                  --argjson bypass_web_search_embedding_and_retrieval "$DESIRED_BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL" \
                  --argjson bypass_web_search_web_loader "$DESIRED_BYPASS_WEB_SEARCH_WEB_LOADER" \
                  '
                    .web.ENABLE_WEB_SEARCH = $enable_web_search
                    | .web.WEB_SEARCH_ENGINE = $web_search_engine
                    | .web.WEB_SEARCH_TRUST_ENV = $web_search_trust_env
                    | .web.WEB_SEARCH_RESULT_COUNT = $web_search_result_count
                    | .web.WEB_SEARCH_CONCURRENT_REQUESTS = $web_search_concurrent_requests
                    | .web.WEB_LOADER_CONCURRENT_REQUESTS = $web_loader_concurrent_requests
                    | .web.WEB_SEARCH_DOMAIN_FILTER_LIST = $web_search_domain_filter_list
                    | .web.BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL = $bypass_web_search_embedding_and_retrieval
                    | .web.BYPASS_WEB_SEARCH_WEB_LOADER = $bypass_web_search_web_loader
                    | .web.BRAVE_SEARCH_API_KEY = $brave_search_api_key
                    | .web.SEARXNG_QUERY_URL = $searxng_query_url
                  '
              )"
              api_post_json "/api/v1/retrieval/config/update" "$payload" "$token" >/dev/null
            }

            fetch_users_json() {
              local token="$1"
              api_get "/api/v1/users/all" "$token" | jq -c '.users // .'
            }

            user_id_for_email() {
              local users_json="$1"
              local email="$2"

              printf '%s' "$users_json" | jq -r --arg email "$email" '.[] | select(.email == $email) | .id' | head -n1
            }

            ensure_user() {
              local email="$1"
              local name="$2"
              local profile_image_url="$3"
              local passfile="$4"
              local role="$5"
              local password
              local payload
              local users_json
              local user_id

              password="$(tr -d '\r\n' < "$passfile")"
              payload="$(
                jq -n \
                  --arg email "$email" \
                  --arg name "$name" \
                  --arg profile_image_url "$profile_image_url" \
                  --arg password "$password" \
                  --arg role "$role" \
                  '{
                    email: $email,
                    name: $name,
                    profile_image_url: $profile_image_url,
                    password: $password,
                    role: $role
                  }'
              )"

              users_json="$(fetch_users_json "$ACTING_TOKEN")"
              user_id="$(user_id_for_email "$users_json" "$email")"

              if [ -n "$user_id" ]; then
                echo "Updating Open WebUI user: $email"
                api_put_json "/api/v1/users/$user_id/update" "$payload" "$ACTING_TOKEN" >/dev/null
                return 0
              fi

              echo "Creating Open WebUI user: $email"
              api_post_json "/api/v1/auths/add" "$payload" "$ACTING_TOKEN" >/dev/null
            }

            prune_undeclared_users() {
              local token="$1"
              local users_json
              local email
              local id
              local keep
              local declared

              users_json="$(fetch_users_json "$token")"
              printf '%s' "$users_json" | jq -c '.[]' | while read -r user; do
                [ -n "$user" ] || continue
                email="$(printf '%s' "$user" | jq -r '.email')"
                keep=0
                for declared in $DECLARED_EMAILS; do
                  if [ "$email" = "$declared" ]; then
                    keep=1
                    break
                  fi
                done

                if [ "$keep" -eq 0 ]; then
                  id="$(printf '%s' "$user" | jq -r '.id')"
                  echo "Removing undeclared Open WebUI user: $email"
                  api_delete "/api/v1/users/$id" "$token" >/dev/null
                fi
              done
            }

            ${passfileLines}

            wait_for_server

            ACTING_EMAIL=""
            ACTING_TOKEN=""

            if ! try_declared_admin_logins; then
              try_bootstrap_first_admin || true
            fi

            if [ -z "$ACTING_TOKEN" ]; then
              try_declared_admin_logins || true
            fi

            if [ -z "$ACTING_TOKEN" ]; then
              recover_admin_token_from_sqlite || true
            fi

            [ -n "$ACTING_TOKEN" ] || {
              echo "Unable to obtain an Open WebUI admin token for reconciliation." >&2
              exit 1
            }

            sync_admin_config "$ACTING_TOKEN"
            sync_openai_config "$ACTING_TOKEN"
            sync_web_search_config "$ACTING_TOKEN"

            ${ensureLines}

            if [ "$PRUNE" = "1" ]; then
              PRUNE_TOKEN="$ACTING_TOKEN"
              if try_declared_admin_logins; then
                PRUNE_TOKEN="$ACTING_TOKEN"
              fi
              prune_undeclared_users "$PRUNE_TOKEN"
            fi
          '';

        restartTriggers = [
          (builtins.toJSON sanitizedUsersForRestart)
        ];
      };
    }

    (lib.mkIf (baseConfigReady && !clusterCfg.enable) (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "openwebui";
        serviceDescription = "Open WebUI";
      }
    ))
  ]);
}
