require 'tempfile'

def assert_equal(actual, expected, message)
  raise message unless actual == expected
end

def test(name, result)
  puts "#{name}"
  wast = `stack exec forest build ./samples/#{name}.tree`

  Tempfile.open("#{name}.wat") do |f|
    f.write(wast)
    f.close

    output = `./wasm-interp #{f.path}`

    exitcode = $?.exitstatus

    assert_equal(
      exitcode,
      result,
      "Expected #{name} to return #{result} but instead got #{exitcode}\n#{output}\n#{wast}"
    )
  end
end

def testCode(name, code, result)
  puts "#{name}"
  wast = nil

  Tempfile.open("sample.tree") do |f|
    f.write(code)
    f.close

    wast = `stack exec forest build #{f.path}`
  end

  Tempfile.open("#{name}.wat") do |f|
    f.write(wast)
    f.close

    output = `./wasm-interp #{f.path}`

    exitcode = $?.exitstatus

    assert_equal(
      exitcode,
      result,
      "Expected #{name} to return #{result} but instead got #{exitcode}\n#{output}\n#{wast}"
    )
  end
end

def run_tests
  test('fib', 89)
  test('let', 15)

  code = <<~FOREST
    main :: Int
    main =
      let
        add1 :: Int -> Int
        add1 n = n + 1

        y :: Int
        y = 10
      in
        y + add1 5
  FOREST

  testCode('complex_let', code, 16)

  code = <<~FOREST
    main :: Int
    main =
      let
        doubleSum :: Int -> Int -> Int
        doubleSum a b =
          let
            double :: Int -> Int
            double n = n * 2
          in
            (double a) + (double b)
      in
        doubleSum 5 10
  FOREST

  testCode('nested_let', code, 5 * 2 + 10 * 2)

  code = <<~FOREST
    test :: Int -> Int
    test a =
      case 5 of
        5 ->
          let
            double :: Int -> Int
            double n = n * 2
          in
            (double 2) + (double 2)
        a -> 10

    main :: Int
    main =
      test 5
  FOREST

  testCode('case_let', code, 8)

  code = <<~FOREST
    data Maybe a
      = Just a
      | Nothing

    test :: Maybe Int -> Int
    test m =
      case m of
        Just a -> a
        Nothing -> 5

    main :: Int
    main = test (Nothing)
  FOREST

  testCode('deconstruction_nothing', code, 5)

  code = <<~FOREST
    data Maybe a
      = Just a
      | Nothing

    test :: Maybe Int -> Int
    test m =
      case m of
        Just a -> a
        Nothing -> 5

    main :: Int
    main = test (Just 10)
  FOREST

  testCode('case_declaration_just', code, 10)

  code = <<~FOREST
    data List
      = Cons Int List
      | Empty

    sum :: List -> Int
    sum l =
      case l of
        Cons x xs -> x + sum xs
        Empty -> 0

    main :: Int
    main = sum (Cons 5 Empty)
  FOREST

  testCode('sum_int_fold', code, 5)

  code = <<~FOREST
    data List a
      = Cons a (List a)
      | Empty

    sum :: List Int -> Int
    sum l =
      case l of
        Cons x xs -> x + sum xs
        Empty -> 0

    main :: Int
    main = sum (Cons 5 (Cons 10 Empty))
  FOREST

  testCode('generic_list_sum_fold', code, 15)

  code = <<~FOREST
    data Player
      = Player Int Int

    getX :: Player -> Int
    getX (Player x y) = x

    main :: Int
    main = getX (Player 30 20)
  FOREST

  testCode('adt_deconstruction_function', code, 30)

  code = <<~FOREST
    main :: Float
    main = 5.0 / 2.0 * 4.0
  FOREST

  testCode('float_infix_ops', code, 10)

  code = <<~FOREST
    data Player
      = Player Float Float

    getX :: Player -> Float
    getX (Player x y) = x

    main :: Float
    main = getX (Player 30.0 20.0)
  FOREST

  testCode('adt_deconstruction_float', code, 30)

  code = <<~FOREST
    data Vector2
      = Vector2 Float Float

    data Player
      = Player Vector2

    getX :: Player -> Float
    getX (Player (Vector2 x y)) = x

    main :: Float
    main = getX (Player (Vector2 30.0 20.0))
  FOREST

  testCode('nested_deconstruction', code, 30)

  code = <<~FOREST
    main :: Int
    main =
      let
        a :: Int
        a = 5

        calc :: Int -> Int
        calc n = n + a
      in
        calc 7
  FOREST

  testCode('closure', code, 12)

  puts 'Integration tests ran successfully!'
end

run_tests
