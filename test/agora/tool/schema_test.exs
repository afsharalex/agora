defmodule Agora.Tool.SchemaTest do
  use ExUnit.Case, async: true

  alias Agora.Tool.Schema

  describe "builders" do
    test "string/1 returns string schema" do
      assert Schema.string() == %{"type" => "string"}
    end

    test "string/1 with description" do
      assert Schema.string(description: "A name") ==
               %{"type" => "string", "description" => "A name"}
    end

    test "string/1 with enum option" do
      assert Schema.string(enum: ["a", "b"]) ==
               %{"type" => "string", "enum" => ["a", "b"]}
    end

    test "integer/1 returns integer schema" do
      assert Schema.integer() == %{"type" => "integer"}
    end

    test "integer/1 with description" do
      assert Schema.integer(description: "Count") ==
               %{"type" => "integer", "description" => "Count"}
    end

    test "number/1 returns number schema" do
      assert Schema.number() == %{"type" => "number"}
    end

    test "boolean/1 returns boolean schema" do
      assert Schema.boolean() == %{"type" => "boolean"}
    end

    test "array/2 returns array schema with items" do
      assert Schema.array(Schema.string()) ==
               %{"type" => "array", "items" => %{"type" => "string"}}
    end

    test "array/2 with description" do
      assert Schema.array(Schema.integer(), description: "Numbers") ==
               %{"type" => "array", "items" => %{"type" => "integer"}, "description" => "Numbers"}
    end

    test "object/2 returns object schema with properties" do
      result =
        Schema.object(%{
          "name" => Schema.string(),
          "age" => Schema.integer()
        })

      assert result == %{
               "type" => "object",
               "properties" => %{
                 "name" => %{"type" => "string"},
                 "age" => %{"type" => "integer"}
               }
             }
    end

    test "object/2 with required fields" do
      result =
        Schema.object(
          %{"name" => Schema.string()},
          required: ["name"]
        )

      assert result["required"] == ["name"]
    end

    test "object/2 with description" do
      result = Schema.object(%{}, description: "A person")
      assert result["description"] == "A person"
    end

    test "enum/2 returns string enum schema" do
      assert Schema.enum(["add", "subtract"]) ==
               %{"type" => "string", "enum" => ["add", "subtract"]}
    end

    test "enum/2 with description" do
      assert Schema.enum(["a"], description: "Op") ==
               %{"type" => "string", "enum" => ["a"], "description" => "Op"}
    end

    test "required/2 adds required fields to existing object schema" do
      schema = Schema.object(%{"name" => Schema.string(), "age" => Schema.integer()})
      refute Map.has_key?(schema, "required")

      with_required = Schema.required(schema, ["name", "age"])
      assert with_required["required"] == ["name", "age"]
      assert with_required["type"] == "object"
      assert with_required["properties"] == schema["properties"]
    end

    test "required/2 overwrites existing required list" do
      schema = Schema.object(%{"a" => Schema.string()}, required: ["a"])
      assert schema["required"] == ["a"]

      updated = Schema.required(schema, ["a", "b"])
      assert updated["required"] == ["a", "b"]
    end
  end

  describe "validate/2 - string" do
    test "valid string" do
      schema = Schema.object(%{"name" => Schema.string()}, required: ["name"])
      assert :ok = Schema.validate(%{"name" => "Alice"}, schema)
    end

    test "invalid string type" do
      schema = Schema.object(%{"name" => Schema.string()})
      assert {:error, [error]} = Schema.validate(%{"name" => 42}, schema)
      assert error =~ "name"
      assert error =~ "expected string"
    end
  end

  describe "validate/2 - integer" do
    test "valid integer" do
      schema = Schema.object(%{"count" => Schema.integer()})
      assert :ok = Schema.validate(%{"count" => 5}, schema)
    end

    test "rejects float for integer" do
      schema = Schema.object(%{"count" => Schema.integer()})
      assert {:error, [error]} = Schema.validate(%{"count" => 5.5}, schema)
      assert error =~ "expected integer"
    end

    test "rejects string for integer" do
      schema = Schema.object(%{"count" => Schema.integer()})
      assert {:error, _} = Schema.validate(%{"count" => "five"}, schema)
    end
  end

  describe "validate/2 - number" do
    test "valid integer as number" do
      schema = Schema.object(%{"val" => Schema.number()})
      assert :ok = Schema.validate(%{"val" => 5}, schema)
    end

    test "valid float as number" do
      schema = Schema.object(%{"val" => Schema.number()})
      assert :ok = Schema.validate(%{"val" => 3.14}, schema)
    end

    test "rejects string for number" do
      schema = Schema.object(%{"val" => Schema.number()})
      assert {:error, _} = Schema.validate(%{"val" => "nope"}, schema)
    end
  end

  describe "validate/2 - boolean" do
    test "valid boolean" do
      schema = Schema.object(%{"flag" => Schema.boolean()})
      assert :ok = Schema.validate(%{"flag" => true}, schema)
      assert :ok = Schema.validate(%{"flag" => false}, schema)
    end

    test "rejects non-boolean" do
      schema = Schema.object(%{"flag" => Schema.boolean()})
      assert {:error, _} = Schema.validate(%{"flag" => "true"}, schema)
    end
  end

  describe "validate/2 - array" do
    test "valid array of strings" do
      schema = Schema.object(%{"tags" => Schema.array(Schema.string())})
      assert :ok = Schema.validate(%{"tags" => ["a", "b"]}, schema)
    end

    test "empty array is valid" do
      schema = Schema.object(%{"tags" => Schema.array(Schema.string())})
      assert :ok = Schema.validate(%{"tags" => []}, schema)
    end

    test "rejects non-array" do
      schema = Schema.object(%{"tags" => Schema.array(Schema.string())})
      assert {:error, [error]} = Schema.validate(%{"tags" => "not_array"}, schema)
      assert error =~ "expected array"
    end

    test "validates items in array with indexed paths" do
      schema = Schema.object(%{"nums" => Schema.array(Schema.integer())})
      assert {:error, errors} = Schema.validate(%{"nums" => [1, "two", 3]}, schema)
      assert length(errors) == 1
      [error] = errors
      assert error =~ "nums.1"
      assert error =~ "expected integer"
    end
  end

  describe "validate/2 - required fields" do
    test "missing required field" do
      schema = Schema.object(%{"name" => Schema.string()}, required: ["name"])
      assert {:error, [error]} = Schema.validate(%{}, schema)
      assert error =~ "missing required field: name"
    end

    test "multiple missing required fields" do
      schema =
        Schema.object(
          %{"a" => Schema.string(), "b" => Schema.string()},
          required: ["a", "b"]
        )

      assert {:error, errors} = Schema.validate(%{}, schema)
      assert length(errors) == 2
    end

    test "present required field passes" do
      schema = Schema.object(%{"name" => Schema.string()}, required: ["name"])
      assert :ok = Schema.validate(%{"name" => "Alice"}, schema)
    end
  end

  describe "validate/2 - enum" do
    test "valid enum value" do
      schema = Schema.object(%{"op" => Schema.enum(["add", "sub"])})
      assert :ok = Schema.validate(%{"op" => "add"}, schema)
    end

    test "invalid enum value" do
      schema = Schema.object(%{"op" => Schema.enum(["add", "sub"])})
      assert {:error, [error]} = Schema.validate(%{"op" => "mul"}, schema)
      assert error =~ "expected one of"
    end

    test "non-string for enum" do
      schema = Schema.object(%{"op" => Schema.enum(["add"])})
      assert {:error, [error]} = Schema.validate(%{"op" => 42}, schema)
      assert error =~ "expected string"
    end
  end

  describe "validate/2 - nested objects" do
    test "valid nested object" do
      schema =
        Schema.object(%{
          "address" =>
            Schema.object(
              %{"city" => Schema.string()},
              required: ["city"]
            )
        })

      assert :ok = Schema.validate(%{"address" => %{"city" => "NYC"}}, schema)
    end

    test "missing required in nested object" do
      schema =
        Schema.object(%{
          "address" =>
            Schema.object(
              %{"city" => Schema.string()},
              required: ["city"]
            )
        })

      assert {:error, [error]} = Schema.validate(%{"address" => %{}}, schema)
      assert error =~ "address.city"
      assert error =~ "missing required field"
    end

    test "type error in nested object" do
      schema =
        Schema.object(%{
          "address" => Schema.object(%{"zip" => Schema.integer()})
        })

      assert {:error, [error]} = Schema.validate(%{"address" => %{"zip" => "abc"}}, schema)
      assert error =~ "address.zip"
      assert error =~ "expected integer"
    end

    test "non-object where object expected" do
      schema = Schema.object(%{"data" => Schema.object(%{"x" => Schema.string()})})
      assert {:error, [error]} = Schema.validate(%{"data" => "not_object"}, schema)
      assert error =~ "expected object"
    end
  end

  describe "validate/2 - edge cases" do
    test "extra fields in args are ignored" do
      schema = Schema.object(%{"name" => Schema.string()})
      assert :ok = Schema.validate(%{"name" => "Alice", "extra" => 42}, schema)
    end

    test "empty schema passes" do
      assert :ok = Schema.validate(%{"anything" => "goes"}, %{})
    end

    test "empty args with no required fields passes" do
      schema = Schema.object(%{"opt" => Schema.string()})
      assert :ok = Schema.validate(%{}, schema)
    end
  end
end
