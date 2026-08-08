ExUnit.start()

Mox.defmock(Bugseeker.Github.Client.Mock, for: Bugseeker.Github.Client)
Mox.defmock(Bugseeker.Llm.DeepSeek.Mock, for: Bugseeker.Llm.DeepSeek)

# All HTTP is mocked in tests; a stray call to a real API should fail loudly.
Application.put_env(:bugseeker, :github_client, Bugseeker.Github.Client.Mock)
Application.put_env(:bugseeker, :llm_client, Bugseeker.Llm.DeepSeek.Mock)

# Fast retries in tests
Application.put_env(:bugseeker, :github_retry_backoff_ms, [1, 1])
Application.put_env(:bugseeker, :llm, %{max_retries: 2, retry_backoff_ms: [1, 1]})

# Sandbox: DB writes are isolated per test. Tests that touch the DB must be
# async: false and check out a connection (see RepoCase).
Ecto.Adapters.SQL.Sandbox.mode(Bugseeker.Repo, :manual)
