{ config, lib, pkgs-unstable, ... }:

let
  cfg = config.alanix.home-assistant.openclawConversation;

  openclawConversationComponent = pkgs-unstable.buildHomeAssistantComponent rec {
    owner = "ddrayne";
    domain = "openclaw";
    version = "1.8.1";

    src = pkgs-unstable.fetchFromGitHub {
      inherit owner;
      repo = "openclaw-homeassistant";
      tag = "v${version}";
      hash = "sha256-i8ww60/pFCpyVQyJLP1TuCaxftkpWxtm1QsIY+NZIxs=";
    };

    postPatch = ''
      substituteInPlace custom_components/openclaw/gateway_client.py \
        --replace-fail \
          '                "sessionKey": self._effective_session_key,' \
          '                "sessionKey": self._effective_session_key,
                "extraSystemPrompt": (
                    "You are responding through Home Assistant Voice PE. Return only "
                    "natural text intended to be spoken aloud. Normally use one or two "
                    "short sentences. Do not use Markdown, bullets, headings, code blocks, "
                    "tables, raw URLs, or emoji. If clarification is necessary, ask one "
                    "short question. You remain the same Jarvis agent and retain normal "
                    "memory and tool access."
                ),'

      substituteInPlace custom_components/openclaw/conversation.py \
        --replace-fail \
          'def trim_tts_text(text: str, max_chars: int) -> str:' \
          'def clean_voice_text(text: str, remove_emojis: bool = True) -> str:
    """Convert agent formatting into natural text suitable for TTS."""
    if remove_emojis:
        text = strip_emojis(text)
        text = re.sub(
            "[\U0001F700-\U0001FAFF\u200D\uFE0F]+",
            "",
            text,
        )
    text = re.sub(r"```(?:\w+)?\n?(.*?)```", r"\1", text, flags=re.DOTALL)
    text = re.sub(r"!\[([^]]*)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"\[([^]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(
        r"(?m)^\s{0,3}(?:#{1,6}\s*|[-*+]\s+|\d+[.)]\s+|>\s*)",
        "",
        text,
    )
    text = re.sub(r"[*_~`]+", "", text)
    text = re.sub(r"\s*\n+\s*", " ", text)
    return re.sub(r"[ \t]{2,}", " ", text).strip()


def trim_tts_text(text: str, max_chars: int) -> str:' \
        --replace-fail \
          '        self._attr_supports_streaming = self._supports_streaming_result()' \
          '        # Buffer the full response so voice cleanup is deterministic.
        self._attr_supports_streaming = False' \
        --replace-fail \
          '        speech = text
        if config.get(CONF_STRIP_EMOJIS, DEFAULT_STRIP_EMOJIS):
            speech = strip_emojis(speech)' \
          '        speech = clean_voice_text(
            text,
            config.get(CONF_STRIP_EMOJIS, DEFAULT_STRIP_EMOJIS),
        )' \
        --replace-fail \
          '        if not self._supports_streaming_result():' \
          '        if not self._attr_supports_streaming:' \
        --replace-fail \
          '        speech_text = (
            strip_emojis(response_text) if should_strip else response_text
        )' \
          '        speech_text = clean_voice_text(response_text, should_strip)'
    '';

    dependencies = [ pkgs-unstable.python3Packages.websockets ];

    meta = {
      changelog = "https://github.com/ddrayne/openclaw-homeassistant/releases/tag/v${version}";
      description = "OpenClaw conversation agent for Home Assistant Assist";
      homepage = "https://github.com/ddrayne/openclaw-homeassistant";
      license = lib.licenses.asl20;
    };
  };
in
{
  options.alanix.home-assistant.openclawConversation = {
    enable = lib.mkEnableOption "the OpenClaw conversation agent for Home Assistant Assist";

    package = lib.mkOption {
      type = lib.types.package;
      default = openclawConversationComponent;
      defaultText = lib.literalExpression "the pinned ddrayne/openclaw-homeassistant component";
      description = "Packaged OpenClaw Home Assistant custom integration to install.";
    };
  };

  config = lib.mkIf (config.alanix.home-assistant.enable && cfg.enable) {
    alanix.home-assistant.customComponents = [ cfg.package ];
  };
}
