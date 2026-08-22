# Local models (Ollama, LM Studio)

Sentwise can draft replies against a model running on your own machine, so
no email content ever leaves it — not even the LLM call. The local provider
speaks the same OpenAI `/v1/chat/completions` wire format as the cloud
OpenAI-compatible provider, so any local runtime that exposes that endpoint
works. This guide covers Ollama (the default) and LM Studio.

## Ollama (recommended)

1. **Install Ollama.** Download it from [ollama.com/download](https://ollama.com/download),
   or with Homebrew:

   ```bash
   brew install ollama
   ```

   Ollama runs a local server on `http://localhost:11434`. Its OpenAI-compatible
   endpoint is `http://localhost:11434/v1`.

2. **Pull a model.** `llama3.1` is a good general-purpose default:

   ```bash
   ollama pull llama3.1
   ```

   The pulled model's name (e.g. `llama3.1`, `llama3.1:8b`, `qwen2.5`) is what
   you enter in the **Model** field in Sentwise. Run `ollama list` to see
   what you have.

3. **Select the provider in Sentwise.** Open **Settings → AI** (the AI tab in
   the Settings window's toolbar; or the onboarding "Choose your AI" step). The
   managed **Sentwise AI** option leads; expand **"Use your own AI provider
   instead"** to reach the bring-your-own controls, then set:

   - **Provider:** `Local (Ollama)` — a one-line note reminds you that local
     models are private but draft quality varies by model (an 8B-parameter model
     or larger is recommended). Click **Use this provider** to make it active.
   - **Model:** leave blank to use `llama3.1`, or type the exact name of a model
     you pulled.
   - **Base URL:** leave blank for Ollama's default
     (`http://localhost:11434/v1`).

   No API key is required for Ollama or LM Studio. If a local/LAN runtime or
   proxy requires one, enter it in **API key (optional)**.

4. **Test Connection.** Click **Test Connection**. On success the provider shows
   **Connected** and drafting/voice-learning use the local model. If it fails,
   make sure the Ollama server is running (`ollama serve`, or just run any
   `ollama run <model>` once) and that the model name matches exactly. During
   first-run onboarding the **Continue** button stays disabled until this test
   passes; the screen says so ("Run Test Connection to continue") so the gate
   isn't a mystery.

## LM Studio

[LM Studio](https://lmstudio.ai) exposes an OpenAI-compatible server too, on a
different port. To use it:

- Start LM Studio's local server (its **Developer / Local Server** tab) and load
  a model.
- In Sentwise, expand **"Use your own AI provider instead"**, choose
  **Local (Ollama)** as the provider and click **Use this provider**, then set the
  **Base URL** to LM Studio's endpoint, typically `http://localhost:1234/v1`.
- Enter the model identifier LM Studio reports for the loaded model, then
  **Test Connection**.

Any other OpenAI-compatible local runtime works the same way — point the Base
URL at its `/v1` endpoint.

## Running the model on another machine (LAN)

You can point Sentwise at a runtime on a different box on your network
(e.g. a Mac Studio or a Linux server with a GPU): set the **Base URL** to that
host's endpoint, such as `http://192.168.1.50:11434/v1`.

**HTTP vs HTTPS.** Plain `http://` is allowed only for local and private-network
addresses (`localhost`, `127.0.0.1`, and LAN IPs) — that's what makes the
loopback and LAN cases above work. Any endpoint reached over the public internet
must use `https://`. If the runtime requires an API key (some proxies do), enter
it in **API key (optional)**; when the field is blank no key is sent.

## How it fits the provider model

The local provider is the OpenAI-compatible adapter with two differences:

- its default endpoint is Ollama's loopback server instead of `api.openai.com`,
  and
- authentication is key-optional — when the key is empty, the `Authorization`
  header is omitted entirely (a bare `Bearer` is rejected by some local
  servers).

Everything else — the model field, the custom Base URL, the "editing the
endpoint forces a re-test" behavior, and how drafts and voice learning are
generated — is identical to the cloud OpenAI-compatible provider.
