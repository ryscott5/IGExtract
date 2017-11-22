utils::globalVariables(c(
  ":=", "statement_ID", "component", "start", "end", "word", ".", "type",
  "features", "inside", "text_ID", "statement_tag", "part_of_speech", "tag",
  "predict", "component_position", "statement_position", "word_original"))

lags_and_leads = function(df, name, window = 0) {
  name = enquo(name)
  if (window > 0) {
    for (i in 1:window) {
      lag_name = paste(quo_name(name), "lag", i, sep = "_")
      lead_name = paste(quo_name(name), "lead", i, sep = "_")
      df =
        df %>%
        mutate(
          !!lag_name := lag(!!name, i, default = "<START>"),
          !!lead_name := lead(!!name, i, default = "<END>")
        )
    }
  }
  df
}

#' Create features for chunking
#'
#' Chunked and unchunked text must be included together. Will return a list
#' with features for both.
#'
#' @import dplyr
#'
#' @param chunked A data frame of chunked text. Include four columns: source (a
#'     source text ID), component (one of ABDICO, if applicable), text (text
#'     of the fragment), and a statement_ID for each statement and segment
#'     of text between statements.
#' @param unchunked A dataframe of unchunked text. Include two columns:
#'     source (a source text ID) and text (the contexts of the text).
#' @param number_of_words The number of distinct words to use for chunking
#' @param window The number of words before and after each word to use for
#'     chunking
#'
#' @examples
#' chunked = data.frame(
#'   source = c(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1),
#'   text = c("Power plants", "must not", "ever", "pollute", "the air",
#'             "and also",
#'             "sewage plants", "must not", "ever", "pollute", "the water"),
#'   component = c("attribute", "deontic", NA, "aim", "object",
#'                 NA,
#'                 "attribute", "deontic", NA, "aim", "object"),
#'   statement_ID = c(1, 1, 1, 1, 1,
#'                    2,
#'                    3, 3, 3, 3, 3)
#' )
#' unchunked = data.frame(
#'   source = 2,
#'   text = "Chemical plants must not ever pollute the soil"
#' )
#' features(chunked, unchunked, number_of_words = 3, window = 3)
#'
#' @export
features = function(chunked, unchunked, number_of_words = 50, window = 10) {

  texts.initial =
    bind_rows(
      chunked %>% mutate(chunked = TRUE),
      unchunked %>% mutate(chunked = FALSE)
    ) %>%
    mutate(text_ID = 1:n())

  texts =
    texts.initial %>%
    group_by(source, statement_ID) %>%
    summarize(inside =
                component %>%
                is.na %>%
                all %>%
                `!`) %>%
    ungroup %>%
    right_join(texts.initial, by = c("source", "statement_ID"))

  all_texts =
    texts$text %>%
    paste(collapse = " \u241E ")

  words =
    all_texts %>%
    NLP::annotate(list(
      openNLP::Maxent_Sent_Token_Annotator(),
      openNLP::Maxent_Word_Token_Annotator(),
      openNLP::Maxent_POS_Tag_Annotator())) %>%
    as.data.frame %>%
    mutate(word_original =
             all_texts %>%
             stringi::stri_sub(start, end),
           word =
             word_original %>%
             forcats::fct_lump(n = number_of_words, other_level = "<OTHER>") %>%
             as.character,
           text_ID =
             (word == "\u241E") %>%
             cumsum %>%
             {. + 1}) %>%
    filter(type != "sentence", word != "\u241E") %>%
    left_join(texts, by = "text_ID") %>%
    rowwise %>%
    mutate(part_of_speech = features$POS) %>%
    ungroup %>%
    group_by(chunked, source, statement_ID) %>%
    mutate(statement_tag =
             inside %>%
             ifelse(
               ((1:n() == 1)) %>%
                 ifelse("beginning statement", "inside statement"),
               "outside statement"
             )
    ) %>%
    group_by(text_ID) %>%
    mutate(tag =
             is.na(component) %>%
             ifelse(
               "outside component",
               paste(
                 (1:n() == 1) %>%
                   ifelse("beginning", "inside"),
                 component)) %>%
             paste(statement_tag, .)) %>%
    ungroup %>%
    select(chunked, source, word, word_original, part_of_speech, tag) %>%
    group_by(chunked, source) %>%
    lags_and_leads(word, window) %>%
    lags_and_leads(part_of_speech, window) %>%
    ungroup

  words.dummies =
    words %>%
    select(-tag, -source, -chunked, -word_original) %>%
    as.data.frame %>%
    dummies::dummy.data.frame(dummy.classes = "ALL")

  new_names = make.names(names(words.dummies))

  together =
    words.dummies %>%
    stats::setNames(new_names) %>%
    .[!duplicated(new_names)] %>%
    mutate(chunked = words$chunked)

  list(
    chunked =
      together %>%
      mutate(tag = as.factor(words$tag)) %>%
      filter(chunked) %>%
      select(-chunked),
    unchunked =
      together %>%
      mutate(word_original = words$word_original,
             source = words$source) %>%
      filter(!chunked) %>%
      select(-chunked)
  )
}


#' Split data into training and testing data
#'
#' Will return a list with a training and a testing data
#'
#' @param data A data frame
#' @param fraction The percentage of the data to put into the training data
#'
#' @examples
#' chunked = data.frame(
#'   source = c(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1),
#'   text = c("Power plants", "must not", "ever", "pollute", "the air",
#'             "and also",
#'             "sewage plants", "must not", "ever", "pollute", "the water"),
#'   component = c("attribute", "deontic", NA, "aim", "object",
#'                 NA,
#'                 "attribute", "deontic", NA, "aim", "object"),
#'   statement_ID = c(1, 1, 1, 1, 1,
#'                    2,
#'                    3, 3, 3, 3, 3)
#' )
#' unchunked = data.frame(
#'   source = 2,
#'   text = "Chemical plants must not ever pollute the soil"
#' )
#' features = features(chunked, unchunked, number_of_words = 3, window = 3)
#' training_and_testing(features$chunked, fraction = 0.5)
#'
#' @export
training_and_testing = function(data, fraction = 0.6) {
  training_rows =
    data %>%
    select(tag) %>%
    mutate(row = 1:n()) %>%
    group_by(tag) %>%
    sample_frac(fraction) %>%
    .$row

  list(
    training = slice(data, training_rows),
    testing = slice(data, -training_rows)
  )
}

#' Build an chunker
#'
#' Build an chunker based on random forest to chunk text with
#'     institutional grammar
#'
#' @param features_chunked Features of chunked text
#' @param ... Extra parameters to pass to randomForest
#'
#' @examples
#' chunked = data.frame(
#'   source = c(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1),
#'   text = c("Power plants", "must not", "ever", "pollute", "the air",
#'             "and also",
#'             "sewage plants", "must not", "ever", "pollute", "the water"),
#'   component = c("attribute", "deontic", NA, "aim", "object",
#'                 NA,
#'                 "attribute", "deontic", NA, "aim", "object"),
#'   statement_ID = c(1, 1, 1, 1, 1,
#'                    2,
#'                    3, 3, 3, 3, 3)
#' )
#' unchunked = data.frame(
#'   source = 2,
#'   text = "Chemical plants must not ever pollute the soil"
#' )
#' features = features(chunked, unchunked, number_of_words = 3, window = 3)
#' chunker(features$chunked, ntree = 400)
#'
#' @export
chunker = function(features_chunked, ...)
  randomForest::randomForest(tag ~ ., data = features_chunked, ...)

#' Validate a chunker
#'
#' Will return a two way table to assess tagging accuracy. Actual tags will be
#' rows, and predicted tags will be columns.
#'
#' @param chunker a chunker
#' @param testing testing data features
#'
#' @examples
#' chunked = data.frame(
#'   source = c(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1),
#'   text = c("Power plants", "must not", "ever", "pollute", "the air",
#'             "and also",
#'             "sewage plants", "must not", "ever", "pollute", "the water"),
#'   component = c("attribute", "deontic", NA, "aim", "object",
#'                 NA,
#'                 "attribute", "deontic", NA, "aim", "object"),
#'   statement_ID = c(1, 1, 1, 1, 1,
#'                    2,
#'                    3, 3, 3, 3, 3)
#' )
#' unchunked = data.frame(
#'   source = 2,
#'   text = "Chemical plants must not ever pollute the soil"
#' )
#' features = features(chunked, unchunked, number_of_words = 3, window = 3)
#' training_and_testing = training_and_testing(features$chunked, fraction = 0.5)
#' chunker = chunker(training_and_testing$training)
#' validate(chunker, training_and_testing$testing)
#'
#' @export
validate = function(chunker, testing) {
  stats::predict(chunker, newdata = testing) %>%
    table(testing$tag, .)
}

beginnings_to_tags = function(vector)
  cumsum(
    vector == "beginning" |
      (vector == "outside" &
         lag(vector, default = "inside") != "outside"))

#' Chunk text
#'
#' Chunk text with a chunker and unchunked features.
#'
#' @param chunker A chunker
#' @param features_unchunked Unchunked text features
#'
#' @examples
#' chunked = data.frame(
#'   source = c(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1),
#'   text = c("Power plants", "must not", "ever", "pollute", "the air",
#'             "and also",
#'             "sewage plants", "must not", "ever", "pollute", "the water"),
#'   component = c("attribute", "deontic", NA, "aim", "object",
#'                 NA,
#'                 "attribute", "deontic", NA, "aim", "object"),
#'   statement_ID = c(1, 1, 1, 1, 1,
#'                    2,
#'                    3, 3, 3, 3, 3)
#' )
#' unchunked = data.frame(
#'   source = 2,
#'   text = "Chemical plants must not ever pollute the soil"
#' )
#' features = features(chunked, unchunked, number_of_words = 3, window = 3)
#' chunker = chunker(features$chunked)
#' chunk(chunker, features$unchunked)
#'
#' @export
chunk = function(chunker, features_unchunked)
  features_unchunked %>%
  mutate(tag =
           stats::predict(chunker,
                          newdata = features_unchunked)) %>%
  select(source, word_original, tag) %>%
  tidyr::separate(tag, c("statement_position", "statement",
                         "component_position", "component")) %>%
  group_by(source) %>%
  mutate(statement_ID = beginnings_to_tags(statement_position)) %>%
  group_by(source, statement_ID) %>%
  mutate(text_ID = beginnings_to_tags(component_position)) %>%
  group_by(source, statement_ID, text_ID) %>%
  summarize(
    component = first(component),
    text = paste(word_original, collapse = " ")) %>%
  ungroup %>%
  select(-text_ID)