import filepath
import glam/doc.{type Document}
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import simplifile
import squirrel/internal/error.{
  type Error, CannotReadFile, QueryFileHasInvalidName,
}
import squirrel/internal/gleam

/// A query that still needs to go through the type checking process.
///
pub type UntypedQuery {
  UntypedQuery(
    /// The file the query comes from.
    ///
    file: String,
    /// The starting line in the source file where the query is defined.
    ///
    starting_line: Int,
    /// The name of the query, it must be a valid Gleam identifier.
    ///
    name: gleam.ValueIdentifier,
    /// Any comment lines that were preceding the query in the file.
    ///
    comment: List(String),
    /// The text of the query itself.
    ///
    content: String,
  )
}

/// This is exactly the same as an untyped query with the difference that it
/// has also been annotated with the type of its parameters and returned values.
///
pub type TypedQuery {
  TypedQuery(
    file: String,
    starting_line: Int,
    name: gleam.ValueIdentifier,
    comment: List(String),
    content: String,
    params: List(gleam.Type),
    returns: List(gleam.Field),
  )
}

/// Turns an untyped query into a typed one.
///
pub fn add_types(
  to query: UntypedQuery,
  params params: List(gleam.Type),
  returns returns: List(gleam.Field),
) -> TypedQuery {
  let UntypedQuery(
    file: file,
    name: name,
    comment: comment,
    content: content,
    starting_line: starting_line,
  ) = query
  TypedQuery(
    file: file,
    name: name,
    comment: comment,
    content: content,
    starting_line: starting_line,
    params: params,
    returns: returns,
  )
}

// --- PARSING -----------------------------------------------------------------

/// Reads a query from a file.
/// This expects the user to follow the convention of having a single query per
/// file.
///
pub fn from_file(file: String) -> Result(UntypedQuery, Error) {
  let read_file =
    simplifile.read(file)
    |> result.map_error(CannotReadFile(file, _))

  use content <- result.try(read_file)

  // A query always starts at the top of the file.
  // If in the future I want to add support for many queries per file this
  // field will be handy to properly show error messages.
  let file_name =
    filepath.base_name(file)
    |> filepath.strip_extension
  let name =
    gleam.identifier(file_name)
    |> result.map_error(QueryFileHasInvalidName(
      file: file,
      reason: _,
      suggested_name: gleam.similar_identifier_string(file_name)
        |> option.from_result,
    ))

  use name <- result.try(name)
  Ok(UntypedQuery(
    file: file,
    starting_line: 1,
    name: name,
    content: content,
    comment: take_comment(content),
  ))
}

fn take_comment(query: String) -> List(String) {
  do_take_comment(query, [])
}

fn do_take_comment(query: String, lines: List(String)) -> List(String) {
  case string.trim_left(query) {
    "--" <> rest ->
      case string.split_once(rest, on: "\n") {
        Ok(#(line, rest)) -> do_take_comment(rest, [string.trim(line), ..lines])
        _ -> do_take_comment("", [string.trim(rest), ..lines])
      }
    _ -> list.reverse(lines)
  }
}

// --- CODE GENERATION ---------------------------------------------------------

/// Returns the generated code and a set with the needed imports to make it
/// compile.
///
pub fn generate_code(
  version: String,
  query: TypedQuery,
) -> #(String, Set(String)) {
  let TypedQuery(
    file: file,
    name: name,
    content: content,
    comment: comment,
    params: params,
    returns: returns,
    starting_line: _,
  ) = query

  let arg_name = fn(i) { "arg_" <> int.to_string(i + 1) }
  let inputs = list.index_map(params, fn(_, i) { arg_name(i) })
  let inputs_encoders =
    list.index_map(params, fn(p, i) {
      gleam_type_to_encoder(p, arg_name(i)) |> doc.from_string
    })

  let inputs_have_json = list.any(params, gleam.contains_json)
  let inputs_have_list = list.any(params, gleam.contains_list)

  let function_name = gleam.identifier_to_string(name)
  let constructor_name = gleam.identifier_to_type_name(name) <> "Row"
  let constructor_has_option =
    list.any(returns, fn(return) { gleam.contains_option(return.type_) })

  let fun_doc = case comment {
    [] -> "/// Runs the `" <> function_name <> "` query
/// defined in `" <> file <> "`."
    [_, ..] ->
      list.map(comment, string.append("/// ", _))
      |> string.join(with: "\n")
  }
  let fun_doc = fun_doc <> "
///
/// > 🐿️ This function was generated automatically using " <> version <> " of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///"

  let record = case record_doc(version, constructor_name, query) {
    Ok(record) -> record |> doc.append(doc.lines(2))
    Error(_) -> doc.empty
  }

  let code =
    [
      record,
      doc.from_string(fun_doc),
      doc.line,
      fun(function_name, ["db", ..inputs], [
        var("decoder", decoder(constructor_name, returns)),
        pipe_call("pgo.execute", string(content), [
          doc.from_string("db"),
          list(inputs_encoders),
          doc.from_string("decode.from(decoder, _)"),
        ]),
      ]),
    ]
    |> doc.concat
    |> doc.to_string(80)

  let imports =
    ["import decode", "import gleam/pgo"]
    |> append_if(constructor_has_option, "import gleam/option.{type Option}")
    |> append_if(inputs_have_list, "import gleam/list")
    |> append_if(inputs_have_json, "import gleam/json")

  #(code, set.from_list(imports))
}

/// Returns the document of a record type definition if the query warrants its
/// creation: if a query doesn't return anything, then it doesn't make sense
/// to create a new record type and this function will return an `Error`.
///
/// Otherwise it returns the document defining a commented type definition with
/// the name passed in as a parameter.
///
fn record_doc(
  version: String,
  constructor_name: String,
  query: TypedQuery,
) -> Result(Document, Nil) {
  let TypedQuery(name: name, returns: returns, file: file, ..) = query
  use <- bool.guard(when: returns == [], return: Error(Nil))

  let function_name = gleam.identifier_to_string(name)
  let record_doc =
    "/// A row you get from running the `" <> function_name <> "` query
/// defined in `" <> file <> "`.
///
/// > 🐿️ This type definition was generated automatically using " <> version <> " of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///"

  [doc.from_string(record_doc), doc.line, record(constructor_name, returns)]
  |> doc.concat
  |> Ok
}

fn gleam_type_to_decoder(type_: gleam.Type) -> String {
  case type_ {
    gleam.List(type_) -> "decode.list(" <> gleam_type_to_decoder(type_) <> ")"
    gleam.Int -> "decode.int"
    gleam.Float -> "decode.float"
    gleam.Bool -> "decode.bool"
    gleam.String -> "decode.string"
    gleam.Option(type_) ->
      "decode.optional(" <> gleam_type_to_decoder(type_) <> ")"
    gleam.Json -> "decode.string"
  }
}

fn gleam_type_to_encoder(type_: gleam.Type, name: String) {
  case type_ {
    gleam.List(type_) ->
      "pgo.array(list.map("
      <> name
      <> ", fn(a) {"
      <> gleam_type_to_encoder(type_, "a")
      <> "}))"
    gleam.Option(type_) ->
      "pgo.nullable(fn(a) {"
      <> gleam_type_to_encoder(type_, "a")
      <> "}, "
      <> name
      <> ")"
    gleam.Int -> "pgo.int(" <> name <> ")"
    gleam.Float -> "pgo.float(" <> name <> ")"
    gleam.Bool -> "pgo.bool(" <> name <> ")"
    gleam.String -> "pgo.text(" <> name <> ")"
    gleam.Json -> "pgo.text(json.to_string(" <> name <> "))"
  }
}

fn gleam_type_to_field_type(type_: gleam.Type) -> Document {
  case type_ {
    gleam.List(type_) -> call("List", [gleam_type_to_field_type(type_)])
    gleam.Option(type_) -> call("Option", [gleam_type_to_field_type(type_)])
    gleam.Int -> doc.from_string("Int")
    gleam.Float -> doc.from_string("Float")
    gleam.Bool -> doc.from_string("Bool")
    gleam.String -> doc.from_string("String")
    gleam.Json -> doc.from_string("String")
  }
}

// --- CODE GENERATION PRETTY PRINTING -----------------------------------------
// These are just a couple of handy helpers to make it easier to generate code
// for a query.
//
// It makes a best effort to also make the generated code look nice.
// Due to some missing features in `glam`, it doesn't reimplement 100% of
// Gleam's own pretty printer so it might have a different look in some places.
//

const indent = 2

pub fn record(name: String, fields: List(gleam.Field)) -> Document {
  let fields =
    list.map(fields, fn(field) {
      let label = gleam.identifier_to_string(field.label)

      [doc.from_string(label <> ": "), gleam_type_to_field_type(field.type_)]
      |> doc.concat
      |> doc.group
    })

  [
    doc.from_string("pub type " <> name <> " {"),
    [doc.line, call(name, fields)]
      |> doc.concat
      |> doc.nest(by: indent),
    doc.line,
    doc.from_string("}"),
  ]
  |> doc.concat
  |> doc.group
}

/// A pretty printed public function definition.
///
pub fn fun(name: String, args: List(String), body: List(Document)) -> Document {
  let args = list.map(args, doc.from_string)

  [
    doc.from_string("pub fn " <> name),
    comma_list("(", args, ") "),
    block([body |> doc.join(with: doc.lines(2))]),
    doc.line,
  ]
  |> doc.concat
  |> doc.group
}

/// A pretty printed let assignment.
///
pub fn var(name: String, body: Document) -> Document {
  [
    doc.from_string("let " <> name <> " ="),
    [doc.space, body]
      |> doc.concat
      |> doc.group
      |> doc.nest(by: indent),
  ]
  |> doc.concat
}

/// A pretty printed Gleam string.
///
/// > ⚠️ This function escapes all `\` and `"` inside the original string to
/// > avoid generating invalid Gleam code.
///
pub fn string(content: String) -> Document {
  let escaped_string =
    content
    |> string.replace(each: "\\", with: "\\\\")
    |> string.replace(each: "\"", with: "\\\"")
    |> doc.from_string

  [doc.from_string("\""), escaped_string, doc.from_string("\"")]
  |> doc.concat
}

/// A pretty printed Gleam list.
///
pub fn list(elems: List(Document)) -> Document {
  comma_list("[", elems, "]")
}

/// A decoder that discards its value and always returns `Nil` instead.
///
const nil_decoder = "decode.map(decode.dynamic, fn(_) { Nil })"

/// A pretty printed decoder that decodes an n-item dynamic tuple using the
/// `decode` package.
///
pub fn decoder(constructor: String, returns: List(gleam.Field)) -> Document {
  use <- bool.guard(when: returns == [], return: doc.from_string(nil_decoder))

  let parameters =
    list.map(returns, fn(field) {
      let label = gleam.identifier_to_string(field.label)
      doc.from_string("use " <> label <> " <- decode.parameter")
    })

  let pipes =
    list.index_map(returns, fn(field, i) {
      let position = int.to_string(i) |> doc.from_string
      let decoder = gleam_type_to_decoder(field.type_) |> doc.from_string
      call("|> decode.field", [position, decoder])
    })

  let labelled_names =
    list.map(returns, fn(field) {
      let label = gleam.identifier_to_string(field.label)
      doc.from_string(label <> ": " <> label)
    })

  [
    call_block("decode.into", [
      doc.join(parameters, with: doc.line),
      doc.line,
      call(constructor, labelled_names),
    ]),
    doc.line,
    doc.join(pipes, with: doc.line),
  ]
  |> doc.concat()
  |> doc.group
}

/// A pretty printed function call where the first argument is piped into
/// the function.
///
pub fn pipe_call(
  function: String,
  first: Document,
  rest: List(Document),
) -> Document {
  [first, doc.line, call("|> " <> function, rest)]
  |> doc.concat
}

/// A pretty printed function call.
///
fn call(function: String, args: List(Document)) -> Document {
  [doc.from_string(function), comma_list("(", args, ")")]
  |> doc.concat
  |> doc.group
}

/// A pretty printed function call where the only argument is a single block.
///
fn call_block(function: String, body: List(Document)) -> Document {
  [doc.from_string(function <> "("), block(body), doc.from_string(")")]
  |> doc.concat
  |> doc.group
}

/// A pretty printed Gleam block.
///
fn block(body: List(Document)) -> Document {
  [
    doc.from_string("{"),
    [doc.line, ..body]
      |> doc.concat
      |> doc.nest(by: indent),
    doc.line,
    doc.from_string("}"),
  ]
  |> doc.concat
  |> doc.force_break
}

/// A comma separated list of items with some given open and closed delimiters.
///
fn comma_list(open: String, content: List(Document), close: String) -> Document {
  [
    doc.from_string(open),
    [
      // We want the first break to be nested
      // in case the group is broken.
      doc.soft_break,
      doc.join(content, doc.break(", ", ",")),
    ]
      |> doc.concat
      |> doc.group
      |> doc.nest(by: indent),
    doc.break("", ","),
    doc.from_string(close),
  ]
  |> doc.concat
  |> doc.group
}

// --- UTILS -------------------------------------------------------------------

fn append_if(list: List(a), cond: Bool, value: a) -> List(a) {
  case cond {
    True -> [value, ..list]
    False -> list
  }
}
