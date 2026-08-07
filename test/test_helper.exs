ExUnit.start()

Mox.defmock(Codeseeker.Github.Client.Mock, for: Codeseeker.Github.Client)
Mox.defmock(Codeseeker.Llm.DeepSeek.Mock, for: Codeseeker.Llm.DeepSeek)

# All HTTP is mocked in tests; a stray call to a real API should fail loudly.
Application.put_env(:codeseeker, :github_client, Codeseeker.Github.Client.Mock)
Application.put_env(:codeseeker, :llm_client, Codeseeker.Llm.DeepSeek.Mock)

# Fast retries in tests
Application.put_env(:codeseeker, :github_retry_backoff_ms, [1, 1])
Application.put_env(:codeseeker, :llm, %{max_retries: 2, retry_backoff_ms: [1, 1]})
