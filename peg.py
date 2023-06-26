# from parsimonious.grammar import Grammar
# import sys
# sys.setrecursionlimit(10000)
import tatsu


rules = r"""
    @@grammar::USFM

    start = document $ ;

    document       =  {element}* ;
    element        =  tag_start [text] {(inline_element [text])}* [text] ;
    inline_element =  element [attributes] tag_end ;

    tag_start      =  backslash tag_id ws ;
    tag_end        =  backslash [tag_id] "*" ;
    attributes     =  [(pipe {pair}*)] ;

    pair           =  key [("=" value)] ;
    key            =  tag_id ;
    value          =  /"[^\"]*"/ ;

    text           =  /[^\\\\|]*/ ;
    ws             =  /\s*/ ;
    tag_id         =  /[A-Za-z][A-Za-z0-9-]*/ ;
    backslash      =  "\\" ;
    pipe           =  "|" ;
    """

def single_simple_tag(grammar):
    text = "\\id GEN EN_ULT en_English_ltr"
    grammar.parse(text)

def double_simple_tag(grammar):
    text = """
    \\id GEN EN_ULT en_English_ltr
    \\usfm 3.0
    """
    grammar.parse(text)

def single_attribute(grammar):
    text = """
    \\v 1 \\w hello | x-occurences = "1"\\w*
    """
    grammar.parse(text)

def single_empty_attribute(grammar):
    text = """
    \\v 1 \\w hello | x-lemma = ""\\w*
    """
    grammar.parse(text)

def self_closing_tag(grammar):
    text = """
    \\p
    \\zaln-s\\*
    """
    grammar.parse(text)

def inner_elements(grammar):
    text = """
    \\v 1 \\zaln-s |x-strong="b:H7225" x-morph="He,R:Ncfsa"\\*\\w In\\w*
    """
    grammar.parse(text)

def ending_text(grammar):
    text = """
    \\v 1
    \\w empty|x-occurrence="1" x-occurrences="1"\\w*\\zaln-e\\*,
    \\zaln-s\\*
    """
    grammar.parse(text)

def self_closing_attributes(grammar):
    text = """
    \\v 1
    \\zaln-s |x-strong="b"\\*
    \\w hello \\w*
    \\zaln-e\\*
    """
    print(grammar.parse(text))

def full_text(grammar):
    with open('../en_ult/01-GEN.usfm', 'r') as f:
        text = '\n'.join(f.read().split('\n')[0:10000])
        print(grammar.parse(text))

if __name__ == '__main__':
    grammar = tatsu.compile(rules)
    single_simple_tag(grammar)
    double_simple_tag(grammar)
    single_attribute(grammar)
    single_empty_attribute(grammar)
    self_closing_tag(grammar)
    inner_elements(grammar)
    ending_text(grammar)
    self_closing_attributes(grammar)
    # full_text(grammar)
