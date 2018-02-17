\long\def\ignore{}

\ignore{
\begin{code}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
module Part5
  ( Token (..)
  , List (..)
  , parseRPN
  , evalRPN
  , rpn
  , chrono
  ) where

import Part1 (Term (..))
import Part2
import Part3
import Part4

import Control.Arrow ((>>>), (<<<), (|||), (&&&))
import Data.Functor.Compose
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe
import Data.Char
import Text.Read (readMaybe)
import Data.Monoid
import Debug.Trace
\end{code}
}

\emph{Previous installments:
  \href{http://blog.sumtypeofway.com/an-introduction-to-recursion-schemes/}{1},
  \href{http://blog.sumtypeofway.com/recursion-schemes-part-2/}{2},
  \href{http://blog.sumtypeofway.com/recursion-schemes-part-iii-folds-in-context/}{3},
  \href{http://blog.sumtypeofway.com/recursion-schemes-part-iv-time-is-of-the-essence/}{4},
  \href{http://blog.sumtypeofway.com/recursion-schemes-part-41-2-better-living-through-base-functors/}{4½}.}

Thus far, we've explored a menagerie of recursion schemes. Catamorphisms and anamorphisms fold and unfold over
data structures, paramorphisms and apomorphisms fold with extra information, and histomorphisms and
futumorphisms allow us to fold and unfold with access to the history and future of the fold and unfold.

At each stage, we derived an unfold by `reversing the arrows' of the fold—put another way, we computed the
categorical dual of each fold operation. Given that fact that we can derive an unfold from a fold (and vice
versa), and given the powerful tool in our toolbox that is function composition,
the next question\footnote{I admit that previous entry in this series stated that the next question we'd
  consider is the laws that the various recursion schemes obey; however, the fact that the schemes under
  discussion in this entry also obey their own set of laws, I felt we should introduce them before considering
  the laws at large. In other words, I lied.} we should ask is ``what happens when we compose an
unfold with a fold?'' In this entry, we'll explore the structures generated from such compositions. (This
post is literate Haskell; you can find the code
\href{https://github.com/patrickt/recschemes/blob/master/src/Part5.lhs}{here}.)

Meijer et. al answered the above question in \emph{
  \href{https://maartenfokkinga.github.io/utwente/mmf91m.pdf}{Bananas, Lenses, Envelopes, and Barbed Wire}}.
They called this concept—unfolding a data structure from a seed value, then computing a final result by folding
over that data structure—a hylomorphism\footnote{
  If you Google `hylomorphism', the results will be almost concerned with Aristotle's
  \href{https://en.wikipedia.org/wiki/Hylomorphism}{philosophical theory} of the same name. Though Aristotle's
  concept is not particularly relevant to the study of recursion schemes, we'll discuss why this name is
  appropriate for the computation that our hylomorphism performs.}. The hylomorphism is sometimes referred to
as a `refold', which is a slightly more approachable but not particularly illustrative name—the streaming literate describes the concept of `producer' and `consumer' functions, and a perhaps-more-meaningful name for a hylomorphism is a `producer-consumer function'.

If you grasp the concept of a catamorphism (a fold) and an anamorphism (an unfold), a hylomorphism is easy:
it's just an unfold followed by a fold. The unfold creates a nested structure out of a seed value, and the
fold tears the resulting structure down into a final value. Here's the definition:

\begin{code}
hylo :: Functor f => Algebra f b -> Coalgebra f a -> a -> b
hylo alg coalg = ana coalg >>> cata alg
\end{code}

Pretty straightforward, right? Unfold with \texttt{ana} and the provided coalgebra, then fold with \texttt{cata}
and the provided algebra.

The `hylo' in `hylomorphism' comes from the Greek \emph{hyle}, ὕλη, meaning `matter'. The ancient Greeks used
`matter' to mean the substance out of which an object is formed (`morpho`); as such, we can read
`hylomorphism' as a function that forms a result object out of some intermediate, constituent matter.

\subsubsection{Highs, Lows, and \texttt{hylo}}

The hylomorphism is more than an elegant result—it generalizes many computations that we as programmers
encounter in our day-to-day work. The canonical example is the factorial function, but an abstraction that
encapsulates building then collapsing a data structure is far more useful than yet another cute way to compute
\texttt{fac(n)}. Though we often don't notice the underlying generality, we're using hylomorphisms every time
we:
\begin{itemize}
  \item aggregate and compute properties of data structures, e.g. determining the mean
  or median or outliers present in a set of numeric data;
  \item apply recursive divide-and-conquer techniques, e.g. quicksort, mergesort, or
  the fast Fourier transform;
  \item determine differences between data structures, e.g. edit distance or Levenshtein
  distance over strings.
\end{itemize}

Let's put \texttt{hylo} to work. We'll build a \href{https://en.wikipedia.org/wiki/Reverse_Polish_notation}{RPN calculator} with \texttt{hylo}. Given the string \texttt{+ 1 2}, our calculator should compute \texttt{1 + 2}, and given \texttt{2 1 12 3 / - +} it should calculate \texttt{(2 + 1) - (12 / 3)}: every RPN postfix expression has one unambiguous parse, obviating the need for parentheses associated with infix operators. Our coalgebra will unfold a list of operations from a seed string, and the algebra will consume the generated list, ultimately yielding a stack of results.

The stack of an RPN calculator contains two types of values: mathematical operations (addition, multiplication,
&c.) and integer literals. We'll define a \texttt{Token} datatype that our calculator will store.

\begin{code}
data Token
  = Lit Int
  | Op (Int -> Int -> Int)
\end{code}

Note that our \texttt{Op} constructor contains a binary function \texttt{Int -> Int -> Int}, rather than
a string representation of the relevant operation. While this precludes a \texttt{Show} instance for
\texttt{Token}, since compiled functions have no meaningful string representation, it will simplify the
implementation: when we parse an \texttt{Op}, we'll store the Haskell
function that corresponds to the operator, so that when we perform computations we need only call the
stored function with the arguments present on the stack.

We need to be able to read a \texttt{Token} out of a string. If we were more principled and honest people, we
would use a parsing library like \href{https://hackage.haskell.org/package/megaparsec}{\texttt{megaparsec}} or
\href{https://hackage.haskell.org/package/trifecta}{\texttt{trifecta}}, or even a \texttt{Maybe} monad to
represent parse failures—but in an effort to keep things simple, let's make this function pure, calling
\texttt{error} if someone decides to get saucy and provide invalid data.

\begin{code}
parseToken :: String -> Token
parseToken "+" = Op (+)
parseToken "-" = Op (-)
parseToken "*" = Op (*)
parseToken "/" = Op div
parseToken num = Lit (fromMaybe (error ("bad token: " ++ num)) (readMaybe num))
\end{code}

Nothing too difficult here. We pattern-match on a given string; given a mathematical operator, we return
an \texttt{Op} containing the corresponding Haskell function; otherwise, we use \texttt{readMaybe} to
yield a \texttt{Lit} value, perishing at runtime if this parse fails.

The easiest way to represent a LIFO stack in Haskell is with a list: we push with a cons operator (\texttt{:})
and pop with by dropping the first item in the list (\texttt{tail}). As such, we'll need a
\texttt{Term}-compatible (parameterized) list type. Though last time we explored how the \texttt{Base}
type family allows us to use Haskell's \texttt{[]} list type with recursion schemes, we'll define our own here.

\begin{code}
data List a b
  = Cons a b
  | Nil
    deriving (Show, Eq, Functor)
\end{code}

Now we have a \texttt{Token} type to operate on and a \texttt{List} type to store tokens. Our next objective
is to define a coalgebra that builds a \texttt{List} of \texttt{Token}s from a \texttt{String}. Remember the
definition of coalgebras from part II:

\begin{verbatim}
type Coalgebra f a = a -> f a
\end{verbatim}


The seed value \texttt{a} will be a \texttt{String}, while the container type \texttt{f} will be
\texttt{List Token}. We'll write the type signature of our coalgebra now:

\begin{verbatim}
parseRPN :: Coalgebra (List Token) String
\end{verbatim}

Keep in mind that \texttt{List Token} here is partially-applied, as \texttt{List} has
three arguments, being of kind \texttt{* -> * -> *}. If we were to expand the \texttt{f a}, we would yield
the type \texttt{List Token String}:

\begin{verbatim}
parseRPN :: String -> List Token String
\end{verbatim}


This makes sense. In each step of our unfold we return a List value containing a \texttt{Token} value
and the remaining \texttt{String} that we have yet to parse, unless the result is \texttt{Nil}, at which point
we stop unfolding, yielding the list. Because \texttt{Nil} contains no children of type \texttt{a} or
\texttt{b}, an occurrence of \texttt{Nil} can assume whatever type we need them to be—here \texttt{Token}
and \texttt{String}.

Now let's implement the body of \texttt{rpn}. The simplest case handles the empty string: if there's no more
input to parse, we terminate the unfold by returning \texttt{Nil}. (\texttt{ana} knows to stop unfolding
if it encounters \texttt{Nil} because the recursive \texttt{fmap} calls will cease: \texttt{Nil} contains
no child nodes into which to recurse.)

\begin{verbatim}
parseRPN ""  = Nil
\end{verbatim}

The case for a nonempty string is more interesting. Given a string \texttt{str}, we take as many characters
from it until we encounter a space. We then pass that chunk into \texttt{parseToken}, sticking its result
into the \texttt{a} field of \texttt{Cons}, then drop all spaces in the remainder of the string and stick
it into the \texttt{b} field of the \texttt{Cons}. We'll use Haskell's \texttt{span} function to do that,
which takes a predicate and returns a tuple containing the items that satisfy the predicate and those
that don't.

\begin{verbatim}
parseRPN str = Cons token newSeed
  where (x, rest) = span (not . isSpace) str
        token     = parseToken x
        newSeed   = dropWhile isSpace rest
\end{verbatim}

Let's look at the function all together:

\begin{code}
parseRPN :: Coalgebra (List Token) String
parseRPN ""  = Nil
parseRPN str = Cons token newSeed
  where (x, rest) = span (not . isSpace) str
        token     = parseToken x
        newSeed   = dropWhile isSpace rest
\end{code}

Not too shabby! Six lines of code, two cases, no compiler warnings. (And this would be even cleaner if we
used an actual parser.) If we run \texttt{ana parseRPN} with \texttt{3 4 +} as a seed value, we yield a
result equivalent to the list \texttt{[Lit 3, Lit 4, Op +]}.

It's time to write our evaluator. Let's consult the definition of an \texttt{Algebra}:

\begin{verbatim}
type Algebra f a = f a -> a
\end{verbatim}

Our container type \texttt{f} will be, as in \texttt{parseRPN}, a \texttt{List Token}. But our result type
\texttt{a} will differ: rather than operating on strings, we want a stack of integers to which we can append
(with \texttt{Lit}) and upon which we can operate (with \texttt{Op}). Let's make a type alias:

\begin{code}
type Stack = [Int]
\end{code}

And now we can set down a type signature for our evaluator:

\begin{verbatim}
evalRPN :: Algebra (List Token) Stack
\end{verbatim}

But this is wrong! Here we have an dilemma: given a reverse-Polish expression: \texttt{2 3 +} or
\texttt{4 2 5 * + 1 3 2 * + /}, we compute the result left-to-right, pushing literals onto the stack and
performing the operations we find on the values in the stack. This means our evaluator must work from the left
(in the manner of \texttt{foldl}) rather than from the right (a la \texttt{foldr}).
But our old friend \texttt{cata} is a right fold—it travels all the way to the \texttt{Nil} at the end of
the list and then propagates its result from the right. How do we work around this, given that \texttt{hylo}
provides us no opportunity to reverse the parsed list of tokens (an admittedly kludgy fix)?

The answer is simple—our result type will not be an ordinary \texttt{Stack} value. We will instead
use a function that takes and returns a \texttt{Stack}: \texttt{Stack -> Stack}. The ultimate result of
this catamorphism will be such a function—we kick off the computation by invoking it with an empty stack.
Since the leftmost element was evaluated most recently, the aggregated function will operate on the leftmost
element first. Further invocations will operate on each subsequent item, left-to-right, until we encounter
the \texttt{Nil} element and cease computation.

If this is difficult to visualize, the following diagram may help:

TODO: diagram

Functional programmers will recognize this as \emph{continuation-passing-style}. And it is! By providing a
continuation function—a function that determines what we do next—we can \emph{fold rightward to build a function that consumes from the left}. The fact that we can use CPS to transform the rightward \texttt{cata}
into a left fold is utterly
staggering to me—as with the fact that \texttt{histo} and \texttt{futu} operate on the cofree comonad and free
monad, it shows that recursion schemes are inextricably interconnected with seemingly-disparate tools in the
toolbox that is functional programming. There is an orchestral beauty to a rigorous, category-theoretical
approach to programming and engineering—my goal in this series has been to shine a light on this beauty.

Let's rewrite \texttt{evalRPN} to use \texttt{Stack -> Stack} as its carrier type:

\begin{verbatim}
evalRPN :: Algebra (List Token) (Stack -> Stack)
\end{verbatim}

That looks right. Our algebra takes a list of tokens and returns a function that takes and returns a stack.
When \texttt{hylo} completes, we'll yield such a function; the value that we provide to that function will
be used as the initial stack. To check our assumptions, we can expand the definition of evalRPN:

\begin{verbatim}
evalRPN :: List Token (Stack -> Stack) -> (Stack -> Stack)
\end{verbatim}

When folding over a list, we need to consider two cases: \texttt{Nil} and \texttt{Cons}. The \texttt{Nil}
case falls out quite easily: we simply return the identity function, as there is no data with which we would
modify a passed-in stack.

\begin{verbatim}
evalRPN Nil = λstack -> stack -- aka `id`
\end{verbatim}

Now let's handle the case of adding a new value onto the stack. Our \texttt{Cons} constructor provides two
values: a \texttt{Lit} that contains an integer, and our accumulator/carrier type, a function from
\texttt{Stack} to \texttt{Stack}. We'll call that \texttt{cont}, since we'll continue evaluation by
invoking it. (If, for some reason, we wanted to terminate early, we would return a function that did not
invoke the provided continuation.) As such, the function we return will take a stack, push the integer
from the \texttt{Lit} value onto that stack, and invoke \texttt{cont} to continue to the next stage:

\begin{verbatim}
evalRPN (Cons (Lit i) cont) = λstack -> cont (i : stack)
\end{verbatim}

The case of applying a function to the stack is similar, except our returned function
has to introspect the top two values so as to have some operands to the provided \texttt{Op}.
As such, we use a \texttt{case} statement that introspects the \texttt{stack} argument to pop off
its top two values. We then apply those operands to the function inside the \texttt{Op}, append
that value to the stack, and invoke \texttt{cont} to proceed to the next stage. If there are
too few values on the stack, we call \texttt{error} to bail out\footnote{
  We could ensure that there are always sufficient values on our stack: if our calculator is
  initialized with an infinite list for a stack (such as \texttt{[0, 0..]}, an infinite sequence of zeroes),
  we could omit the error case.}. After applying the function contained in the \texttt{Op} value to
these two values,
we append the result of this function to the remainder of the list, then call the continuation to
proceed to the next computational stage.

\begin{verbatim}
evalRPN (Cons (Op fn) cont) = λstack -> case stack of
  (a : b : rest) -> cont (fn b a : rest)
  _              -> error ("too few arguments on stack: " <> show stack)
\end{verbatim}

I wrote this using explicit lambdas to make it clear that each step of the evaluation returns a function, one
that determines what to do next by invoking the continuation that is the algebra's carrier type. But these
lambdas are necessary: since Haskell doesn't distinguish between a unary function that returns a lambda and
a binary function that returns a value, we can write \texttt{evalRPN} a little more naturally, providing a
\texttt{stack} argument to the function itself\footnote{Put another way, Haskell makes no distinction
between the types \texttt{a -> (b -> c)} and \texttt{a -> b -> c}}.

\begin{code}
evalRPN :: Algebra (List Token) (Stack -> Stack)
evalRPN Nil stack                      = stack
evalRPN (Cons (Lit i) cont) stack      = cont (i : stack)
evalRPN (Cons (Op fn) cont) (a:b:rest) = cont (fn b a : rest)
evalRPN _ stack                        = error ("too few arguments on stack: " <> show stack)
\end{code}

I find this significantly to read: it shows clearly that evaluation terminates in the \texttt{Nil} case,
and continues in the \texttt{Cons} cases by virtue of invoking the carried \texttt{cont} function.

Now we have a coalgebra (the parser) and an algebra (the evaluator, in continuation-passing style).
Let's put it all together—we can start by interrogating GHCi as to the type of passing these to \texttt{hylo}.

\begin{verbatim}
λ> :t hylo evalRPN parseRPN
hylo evalRPN parseRPN :: String -> Stack -> Stack
\end{verbatim}

That makes sense: the \texttt{String} parameter is our input, and the \texttt{Stack} parameter is the
initial value of the RPN machine's stack. So now we can build a top-level \texttt{rpn} function that takes
a string, invoking the result of \texttt{hylo} with the provided string and an empty initial stack:

\begin{code}
rpn :: String -> Stack
rpn s = hylo evalRPN parseRPN s []
\end{code}

We can test this by evaluating it in GHCi:

\begin{verbatim}
λ> rpn "15 7 1 1 + - / 3 * 2 1 1 + + -"
[5]
\end{verbatim}

Though an RPN calculator isn't enormously complicated, I'd argue that our implementation demonstrates the
virtue of recursion schemes: by separating \emph{what} we're doing from \emph{how} we're doing it, we
draw attention to the meat of the problem—parsing from a string and operating on a stack—without concerning
ourselves with the details of aggregating data from an input string or iterating over a parsed sequence
of tokens. The machinery of unfolding and folding is all contained within \texttt{hylo}: all we have to
worry about is the core of our problem. And that's pretty remarkable.

\subsubsection{Further Efficiency}

We don't need to invoke cata and ana explicitly to build a hylomorphism.
We can build \texttt{hylo} just out of the algebra and coalgebra itself.

\begin{code}
hylo' :: Functor f => Algebra f b -> Coalgebra f a -> a -> b
hylo' alg coalg = coalg >>> fmap (hylo' alg coalg) >>> alg
\end{code}

Though this definition is arguably less indicative of the fact that a hylomorphism is the composition of an
an anamorphism and catamorphism, it bears a compelling property: it entails half as many calls to \texttt{fmap}
as does the previous definition.

Our original \texttt{hylo} unfolded our \texttt{List} to its maximum extent,
entailing O(n) calls to \texttt{fmap}, where n is the number of tokens passed to \texttt{rpn}. Subsequently,
that structure is torn down with \texttt{cata}, using an additional O(n) calls to fmap. In contrast, this new
definition of \texttt{hylo} only recurses O(n) rather than O(2n) times: as soon as the unfolding completes and
the recursive \texttt{fmap} invocations bottom out, each level of the structure is passed directly to
\texttt{alg} as the stack unwinds. This is a significant optimization, especially for deeply-nested structures!

\subsubsection{Time is Running Out (and In)}

Though Meijer et al. introduced the hylomorphism along with the catamorphism and anamorphism,
Uustalu and Vene's paper does not mention what happens when you compose a histomorphism and
futumorphism. It appears to have taken until roughly 2008 (nine whole years!), when Edward Kmett
and the #haskell IRC channel dubbed it the chronomorphism—chrono (χρόνος) being the prefix related
to time.

The definition of the chronomorphism follows from that of the hylomorphism:

\begin{code}
chrono :: Functor f => CVAlgebra f b -> CVCoalgebra f a -> a -> b
chrono cvalg cvcoalg = futu cvcoalg >>> histo cvalg
\end{code}

Pretty straightforward: \texttt{futu} unfolds a structure multiple layers at a time (thanks to the power of
the free monad), and \texttt{histo} tears it down.

Unfortunately, coming up with a useful example of chronomorphisms is a bit more difficult than
that of a hylomorphism. The plant-growing example in part IV of this series comes close—we used a
futumorphism to generate plant life, but only used a catamorphism, rather than a histomorphism, to
render the resulting plant. We could have expressed that catamorphism as a histomorphism, as we showed
when we implemented \texttt{cata} in terms of \texttt{histo}, but bringing in the power of histomorphisms
and not using them is pretty pointless. I haven't been able to find a useful or illustrative of \texttt{chrono}
in action (if you know of one, get in touch!) but I at least have the reassurance that Kmett himself
\href{https://
twitter.com/kmett/status/318410115101380608}{can't think of one either.} \texttt{chrono} can,
however, be used to implement the \emph{dynamorphism}, a scheme specialized towards solving dynamic programming
problems, which we will discuss in future installments. (It's possible that Uustalu and Vene neglected to
mention the chronomorphism for precisely this reason—it's hard to find a truly compelling use case for it.)

\subsubsection{Taking Shortcuts with Elgot (Co)Algebras}

Histomorphisms are useful: building up and then collapsing some intermediate structure is a pattern worth
abstracting, as separating `what' from `how' always gains us some degree of insight into our code. But in
practice, this process of construction and destruction is often interrupted. Perhaps, during the construction
of our intermediate structure, we determine that the input data violates our assumptions, requiring us to
terminate the construction early; perhaps, during destruction, we enter an optimizable state that allows us
to skip future destruction steps.

While we could use failure monads over \texttt{hylo} to represent these patterns, a paper by Jiří Adámek,
Stefan Milius, and Jiří Velebil, entitled \href{https://arxiv.org/pdf/cs/0609040.pdf}{Elgot Algebras},
provides us with a category-theoretical treatment of this pattern, avoiding the hornet's nest that is
impurity. Named after Calvin Elgot, an American mathematician who worked for many decades in the intersection
between software engineering and pure mathematics, Elgot algebras and coalgebras generalize hylomorphisms,
catamorphisms, and apomorphisms in a manner both elegant and useful.

Let's consider the type signature of a hylomorphism. Rather than just repeat our first type signature,
let's look at \texttt{hylo} after we expand the \texttt{Algebra} and \texttt{Coalgebra} type synonyms.

\begin{verbatim}
hylo :: Functor f => (f b -> b) -> (a -> f a) -> a -> b
\end{verbatim}

This tells us, given a F-coalgebra over \texttt{a} and an F-algebra over \texttt{b}, how to get from an
\texttt{a} to a \texttt{b}. But what if we could take a shortcut? If, in our coalgebra (the `construction'
function), we could short-circuit the whole hylomorphism, returning a plain \texttt{b} value, we could
provide this refold function with an escape hatch—without having to worry about the semantics of
\texttt{Maybe} or \texttt{Either} or \texttt{Except} or whatever failure monad we would use with plain
\texttt{hylo}.

To allow this, our coalgebra, \texttt{a -> f a}, has to be able to return one of two values—an \texttt{f a},
which continues the unfold, or a \texttt{b}, short-circuiting it. Haskell provides us a mechanism to return
one of two values, of course: the trusty \texttt{Either} type. Changing our coalgebra to return an
\texttt{Either} type yields us with the type signature for \texttt{Elgot}, the Elgot algebra:

\begin{verbatim}
elgot :: Functor f => Algebra f b -> (a -> Either b (f a)) -> a -> b
\end{verbatim}

We'll use an auxiliary functions to define Elgot algebras: \texttt{|||} (pronounced `fanin'). It is an
infix form of the \texttt{either} helper function: given  two functions, one of type \texttt{b -> a}
and the other of type \texttt{c -> a}, it creates a function that takes \texttt{Either} a \texttt{b}
or a \texttt{c} and returns an \texttt{a}.

\begin{verbatim}
(|||) :: (b -> a) -> (c -> a) -> (Either b c -> a)
\end{verbatim}

Reading \texttt{|||} as `or' can be a helpful mnemonic: we can see that \texttt{f ||| g} returns a function
that uses \texttt{f} \emph{or} \texttt{g}.

Defining \texttt{elgot} follows straightforwardly from the above optimized definition of \texttt{hylo}.
We begin by invoking our coalgebra. If we get a \texttt{Right} value out of it, we recurse into it,
eventually passing this layer of the computation on to our coalgebra—in other words, it behaves like
a normal call to \texttt{hylo}. But if we get a \texttt{Left} value, we just stop, performing no operation
on the value contained therein.

\begin{code}
elgot :: Functor f => Algebra f b -> (a -> Either b (f a)) -> a -> b
elgot alg coalg = coalg >>> (id ||| (fmap (elgot alg coalg) >>> alg))
\end{code}

By using \texttt{|||} to handle the Either case: performing \texttt{id} (no operation) on a \texttt{Left}
value and recursing on a \texttt{Right} value, we gain a clarity of definition—but more importantly, we
make it easy to `reverse the arrows'. Every time we reverse the arrows on a fold, we yield the corresponding
unfold: but here, reversing the arrows on an Elgot coalgebra, we yield a hylomorphism that can short-circuit
during \emph{destruction}, rather than construction.

We know how to reverse most of the operations in the above definition: \texttt{alg} becomes \texttt{coalg}
and vice versa, \texttt{>>>} becomes \texttt{<<<} and vice versa, and \texttt{id} stays the same,
being its own dual. The \texttt{|||} may be slightly less obvious, but if we remember that tuples
(\texttt{,}) are dual to \texttt{Either}, we yield the \texttt{&&&} operator, pronounced `fanout':

\begin{verbatim}
(&&&) :: (a -> b) -> (a -> c) -> (a -> (b, c))
\end{verbatim}

Whereas \texttt{|||} took two functions and used one or either of them to deconstruct an \texttt{Either},
\texttt{&&&} takes two functions and uses both of them to construct a tuple: given one of type
\texttt{a -> b} and the other of type \texttt{a -> c}, we can apply them both on a given \texttt{a} to
yield a tuple of type \texttt{(b, c)}. Again, reading the ampersand as `and' can be a useful memonic:
\texttt{f &&& g} returns a function that uses both \texttt{f} `and' \texttt{g}.

Now we know how to reverse every operation in \texttt{elgot}. Let's do so:

\begin{verbatim}
coelgot alg coalg = alg <<< (id &&& (fmap (coelgot alg coalg) <<< coalg))
\end{verbatim}

Feeding this into GHCi and querying its type yields the following lovely signature:

\begin{verbatim}
coelgot :: Functor f => ((a, f b) -> b) -> (a -> f a) -> a -> b
\end{verbatim}

Our algebra, which previously took an \texttt{f b}, now takes a tuple—\texttt{(a, f b)}. That \texttt{a} is
the same \texttt{a} used to generate the \texttt{f b} we are examining. The `shortcut' behavior here is
slightly more subtle than that present in the definition of \texttt{elgot}—it depends on Haskell's call-by-need
semantics.

By replacing \texttt{a -> f a} with its natural type synonym, \texttt{Coalgebra}, we yield a unified
definition of \texttt{coelgot}.

\begin{code}
coelgot :: Functor f => ((a, f b) -> b) -> Coalgebra f a -> a -> b
coelgot alg coalg = alg <<< (id &&& (fmap (coelgot alg coalg) <<< coalg))
\end{code}

We can think of Elgot algebras as a hylomorphism built out of an \texttt{RCoalgebra} and an \texttt{Algebra}.
Dually, we can think of Elgot coalgebras as hylomorphisms built out of an \texttt{RAlgebra} and a
\texttt{Coalgebra}. We can also build a more powerful hylomorphism out of both an \texttt{RAlgebra} and
\texttt{RCoalgebra}:

\begin{code}
hylo'' :: Functor f => RAlgebra f b -> RCoalgebra f a -> a -> b
hylo'' ralg rcoalg = apo rcoalg >>> para ralg
\end{code}

As far as I can tell, there is no separate name for this construction; I'd refer to it as an
``R-hylomorphism'', which has a ring to it. (If you know the name for this construction, drop me a line.)