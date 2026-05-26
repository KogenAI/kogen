# ash - Relationships Between Resources

## Relationship Types

Ash provides four core relationship types that describe connections between resources. Each type specifies how records relate to each other and which resource stores the foreign key.

## belongs_to

A `belongs_to` relationship stores a foreign key on the source resource. The source has an attribute (default: `:<relationship_name>_id`) that uniquely identifies a record in the destination resource.

### Basic Definition

```elixir
defmodule MyApp.Tweets.Tweet do
  use Ash.Resource

  attributes do
    uuid_primary_key :id
    attribute :text, :string
  end

  relationships do
    belongs_to :author, MyApp.Accounts.User
  end
end
```

The framework automatically creates an `:author_id` attribute on tweets linking to users' `:id` field.

### Loading Related Data

```elixir
# Load the author when reading tweets
tweet =
  MyApp.Tweets.Tweet
  |> Ash.Query.filter(id: tweet_id)
  |> Ash.Query.load(:author)
  |> Ash.read_one!()

IO.inspect(tweet.author)  # Access author data
```

### Custom Foreign Key

```elixir
relationships do
  belongs_to :owner, MyApp.Accounts.User do
    foreign_key :owner_id
    primary_key :id
  end
end
```

## has_one

A `has_one` relationship places the foreign key on the _destination_ resource but enforces a one-to-one connection. "There is a unique attribute on the destination resource that identifies a record with a matching unique attribute in the source."

### Use Case: Related Single Record

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource

  attributes do
    uuid_primary_key :id
    attribute :name, :string
  end

  relationships do
    # User has one profile
    has_one :profile, MyApp.Accounts.Profile do
      foreign_key :user_id
    end
  end
end

defmodule MyApp.Accounts.Profile do
  use Ash.Resource

  attributes do
    uuid_primary_key :id
    attribute :bio, :string
  end

  relationships do
    belongs_to :user, MyApp.Accounts.User
  end
end
```

### Loading

```elixir
# Load the single related profile
user =
  MyApp.Accounts.User
  |> Ash.Query.filter(id: user_id)
  |> Ash.Query.load(:profile)
  |> Ash.read_one!()

IO.inspect(user.profile)
```

## has_many

Similar to `has_one`, but the destination attribute is non-unique, producing a list of related records.

### Basic Definition

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource

  attributes do
    uuid_primary_key :id
    attribute :name, :string
  end

  relationships do
    has_many :tweets, MyApp.Tweets.Tweet do
      foreign_key :author_id
    end
  end
end

defmodule MyApp.Tweets.Tweet do
  use Ash.Resource

  relationships do
    belongs_to :author, MyApp.Accounts.User
  end
end
```

### Sorting and Filtering

```elixir
# Load tweets with custom sorting
user =
  MyApp.Accounts.User
  |> Ash.Query.filter(id: user_id)
  |> Ash.Query.load(
    tweets: Ash.Query.sort(MyApp.Tweets.Tweet, [inserted_at: :desc])
  )
  |> Ash.read_one!()

# Access list of tweets
Enum.each(user.tweets, fn tweet ->
  IO.inspect(tweet.text)
end)
```

### Loading with Custom Query

```elixir
tweets_query =
  MyApp.Tweets.Tweet
  |> Ash.Query.filter(status: :published)
  |> Ash.Query.sort(inserted_at: :desc)
  |> Ash.Query.limit(10)

user =
  MyApp.Accounts.User
  |> Ash.Query.load(tweets: tweets_query)
  |> Ash.read_one!()
```

## many_to_many

This type connects multiple source records to multiple destination records through a _join resource_ (pivot table). It combines `has_many` relationships with `belongs_to` relationships on the join table.

### Definition with Join Resource

```elixir
defmodule MyApp.Tweets.Tweet do
  use Ash.Resource

  relationships do
    many_to_many :hashtags, MyApp.Tags.Hashtag do
      through MyApp.Tweets.TweetHashtag
      source_attribute_on_join_resource :tweet_id
      destination_attribute_on_join_resource :hashtag_id
    end
  end
end

defmodule MyApp.Tags.Hashtag do
  use Ash.Resource

  relationships do
    many_to_many :tweets, MyApp.Tweets.Tweet do
      through MyApp.Tweets.TweetHashtag
      source_attribute_on_join_resource :hashtag_id
      destination_attribute_on_join_resource :tweet_id
    end
  end
end

# Join resource (join table)
defmodule MyApp.Tweets.TweetHashtag do
  use Ash.Resource

  relationships do
    belongs_to :tweet, MyApp.Tweets.Tweet
    belongs_to :hashtag, MyApp.Tags.Hashtag
  end
end
```

### Loading Many-to-Many

```elixir
tweet =
  MyApp.Tweets.Tweet
  |> Ash.Query.filter(id: tweet_id)
  |> Ash.Query.load(:hashtags)
  |> Ash.read_one!()

# Access list of hashtags
Enum.each(tweet.hashtags, fn hashtag ->
  IO.inspect(hashtag.name)
end)
```

## Key Usage Patterns

### Managing Relationships in Actions

Use `manage_relationship/3` in changes to handle related record operations:

```elixir
defmodule MyApp.Posts.Post do
  use Ash.Resource

  relationships do
    has_many :comments, MyApp.Posts.Comment
  end

  actions do
    update :update do
      accept [:title, :content]
      change manage_relationship(:comments, on_input: :destroy)
    end
  end
end
```

### Filtering by Relationships

Query based on related data:

```elixir
# Find tweets with #elixir hashtag
MyApp.Tweets.Tweet
|> Ash.Query.load(hashtags: Ash.Query.filter(MyApp.Tags.Hashtag, name: "elixir"))
|> Ash.read!()

# Find users who authored tweets
MyApp.Accounts.User
|> Ash.Query.filter(
  Ash.Expr.expr(exists(tweets, true))
)
|> Ash.read!()
```

### Relationship Constraints

```elixir
defmodule MyApp.Orders.Order do
  use Ash.Resource

  relationships do
    belongs_to :customer, MyApp.Accounts.User do
      required? true  # Customer required
    end

    has_many :items, MyApp.Orders.LineItem do
      dependent_destroy? true  # Delete items when order deleted
    end
  end
end
```

### Nested Loads

```elixir
user =
  MyApp.Accounts.User
  |> Ash.Query.filter(id: user_id)
  |> Ash.Query.load(
    tweets: [
      :author,
      hashtags: Ash.Query.sort(MyApp.Tags.Hashtag, name: :asc)
    ]
  )
  |> Ash.read_one!()

# Access deeply nested data
Enum.each(user.tweets, fn tweet ->
  Enum.each(tweet.hashtags, fn hashtag ->
    IO.inspect(hashtag.name)
  end)
end)
```

---

[← Back to main](ash-3.7.6.md)
**Version:** 3.7.6
