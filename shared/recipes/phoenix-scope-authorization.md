# Recipe: Phoenix Scope-Based Authorization Pattern

## Problem

Traditional Phoenix applications often mix authorization logic throughout the codebase, leading to:

- Data leaks between users/companies due to unfiltered queries
- Inconsistent authorization checks across contexts
- Difficulty auditing data access patterns
- Security vulnerabilities from forgotten authorization filters

## Solution

Implement a comprehensive scope-based authorization system where:

- All context functions accept a Scope struct as the first parameter
- Scope contains user and optional company information for filtering
- System scopes support background operations
- Router pipelines automatically populate scope from session

## Implementation

### 1. Create the Scope Module

```elixir
# lib/your_app/accounts/scope.ex
defmodule YourApp.Accounts.Scope do
  @moduledoc """
  Scope structure for secure data access.
  Contains user and optionally company information for filtering queries.
  """

  alias YourApp.Accounts.User
  alias YourApp.Companies.Company

  @type t :: %__MODULE__{
          user: User.t() | nil,
          company: Company.t() | nil,
          state: String.t() | nil,
          system: boolean()
        }

  defstruct user: nil, company: nil, state: nil, system: false

  @doc "Creates a scope for a user"
  @spec for_user(User.t() | nil) :: t() | nil
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil

  @doc "Creates a system scope for background workers"
  @spec system() :: t()
  def system, do: %__MODULE__{system: true}

  @doc "Adds company to existing scope"
  @spec put_company(t(), Company.t()) :: t()
  def put_company(%__MODULE__{} = scope, %Company{} = company) do
    %{scope | company: company}
  end

  @doc "Helper to get user_id from scope"
  @spec user_id(t()) :: String.t() | nil
  def user_id(%__MODULE__{user: %User{id: id}}), do: id
  def user_id(%__MODULE__{}), do: nil

  @doc "Helper to get company_id from scope"
  @spec company_id(t()) :: String.t() | nil
  def company_id(%__MODULE__{company: %Company{id: id}}), do: id
  def company_id(%__MODULE__{}), do: nil

  @doc "Checks if scope has required access"
  @spec has_access?(t(), atom()) :: boolean()
  def has_access?(%__MODULE__{system: true}, :system), do: true
  def has_access?(%__MODULE__{user: nil}, :user), do: false
  def has_access?(%__MODULE__{user: %User{}}, :user), do: true
  def has_access?(%__MODULE__{company: nil}, :company), do: false
  def has_access?(%__MODULE__{company: %Company{}}, :company), do: true
  def has_access?(_scope, _access_type), do: false
end
```

### 2. Update Router Pipeline

```elixir
# lib/your_app_web/router.ex
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :put_root_layout, html: {YourAppWeb.Layouts, :root}
  plug :protect_from_forgery
  plug :put_secure_browser_headers
  plug :fetch_current_user
  plug :fetch_current_scope  # Add scope fetching
end

defp fetch_current_scope(conn, _opts) do
  user = conn.assigns[:current_user]
  scope = YourApp.Accounts.Scope.for_user(user)
  assign(conn, :current_scope, scope)
end
```

### 3. Update LiveView UserAuth

```elixir
# lib/your_app_web/user_auth.ex
def on_mount(:mount_current_scope, _params, session, socket) do
  {:cont, mount_current_scope(socket, session)}
end

defp mount_current_scope(socket, session) do
  Phoenix.Component.assign_new(socket, :current_scope, fn ->
    user =
      if user_token = session["user_token"] do
        Accounts.get_user_by_session_token(user_token)
      end

    YourApp.Accounts.Scope.for_user(user)
  end)
end
```

### 4. Update Context Functions with TDD Approach

#### Step A: Update Tests First (Red Phase)

```elixir
# test/your_app/job_postings_test.exs
defmodule YourApp.JobPostingsTest do
  use YourApp.DataCase
  import YourApp.AccountsFixtures
  import YourApp.JobPostingsFixtures

  alias YourApp.Accounts.Scope
  alias YourApp.JobPostings

  describe "with employer scope" do
    setup do
      scope = employer_scope_fixture()
      %{scope: scope}
    end

    test "list_job_postings/1 returns company job postings", %{scope: scope} do
      job_posting = job_posting_fixture(%{company_id: scope.company.id})
      other_posting = job_posting_fixture() # Different company

      results = JobPostings.list_job_postings(scope)
      assert job_posting in results
      refute other_posting in results
    end
  end
end
```

#### Step B: Update Context Implementation (Green Phase)

```elixir
# lib/your_app/job_postings.ex
alias YourApp.Accounts.Scope

@type scope :: Scope.t()  # Module-level type alias

@spec list_job_postings(scope()) :: [JobPosting.t()]
def list_job_postings(%Scope{} = scope) do
  query =
    case scope do
      %Scope{user: %User{type: :employer}, company: %Company{id: company_id}} ->
        from jp in JobPosting, where: jp.company_id == ^company_id
      %Scope{user: %User{type: :job_seeker}} ->
        from jp in JobPosting, where: jp.published == true
      %Scope{system: true} ->
        from jp in JobPosting  # System can access all
      _ ->
        from jp in JobPosting, where: false  # No access by default
    end

  Repo.all(query)
end

@spec get_job_posting!(scope(), String.t()) :: JobPosting.t()
def get_job_posting!(%Scope{} = scope, id) do
  query =
    case scope do
      %Scope{user: %User{type: :employer}, company: %Company{id: company_id}} ->
        from jp in JobPosting,
          where: jp.id == ^id and jp.company_id == ^company_id
      %Scope{user: %User{type: :job_seeker}} ->
        from jp in JobPosting,
          where: jp.id == ^id and jp.published == true
      %Scope{system: true} ->
        from jp in JobPosting, where: jp.id == ^id
      _ ->
        from jp in JobPosting, where: false
    end

  Repo.one!(query)
end
```

### 5. Update LiveViews

```elixir
# lib/your_app_web/live/job_posting_live/index.ex
@impl Phoenix.LiveView
def mount(_params, _session, socket) do
  scope = socket.assigns.current_scope

  {:ok,
   socket
   |> assign(:job_postings, JobPostings.list_job_postings(scope))}
end

@impl Phoenix.LiveView
def handle_event("delete", %{"id" => id}, socket) do
  scope = socket.assigns.current_scope
  job_posting = JobPostings.get_job_posting!(scope, id)
  {:ok, _} = JobPostings.delete_job_posting(scope, job_posting)

  {:noreply, assign(socket, :job_postings, JobPostings.list_job_postings(scope))}
end
```

### 6. Update Test Fixtures

```elixir
# test/support/fixtures/accounts_fixtures.ex
def user_scope_fixture(attrs \\ %{}) do
  user = user_fixture(attrs)
  Scope.for_user(user)
end

def employer_scope_fixture(attrs \\ %{}) do
  user = user_fixture(Map.put(attrs, :type, :employer))
  company = company_fixture(%{user_id: user.id})

  Scope.for_user(user)
  |> Scope.put_company(company)
end

def job_seeker_scope_fixture(attrs \\ %{}) do
  user = user_fixture(Map.put(attrs, :type, :job_seeker))
  Scope.for_user(user)
end
```

## Considerations

**Migration Strategy:**

- Use Test-Driven Development (TDD) - update tests first, then implementation
- Migrate one context at a time to avoid overwhelming changes
- Use module-level type aliases to eliminate type duplication
- Run verification commands after each context migration

**Security Benefits:**

- Prevents data leaks between users/companies
- Centralizes authorization logic in scope filtering
- Makes unauthorized access attempts fail explicitly
- Enables easy auditing of data access patterns

**Performance:**

- Scope filtering happens at database level (efficient)
- No N+1 queries introduced by scope pattern
- Can be combined with existing query optimizations

**Testing:**

- Write scope-aware tests that verify authorization boundaries
- Test unauthorized access scenarios (should raise or return empty)
- Use fixtures that create scoped test data

## Example Usage

```elixir
# In background workers - use system scope
def perform(%Oban.Job{}) do
  scope = Scope.system()
  JobPostings.list_job_postings(scope)  # Can access all
end

# In LiveViews - use current user's scope
def mount(_params, _session, socket) do
  scope = socket.assigns.current_scope
  jobs = JobPostings.list_job_postings(scope)  # Filtered by user/company
  {:ok, assign(socket, :jobs, jobs)}
end

# Different users see different data
employer_scope = Scope.for_user(employer) |> Scope.put_company(company)
JobPostings.list_job_postings(employer_scope)  # Only company's jobs

job_seeker_scope = Scope.for_user(job_seeker)
JobPostings.list_job_postings(job_seeker_scope)  # Only published jobs
```

## Related Recipes

- Type Duplication Detection and Resolution
- Phoenix LiveView Authentication Patterns
- Test-Driven Context Migration
