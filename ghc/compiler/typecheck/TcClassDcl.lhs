%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1995
%
\section[TcClassDcl]{Typechecking class declarations}

\begin{code}
module TcClassDcl ( tcClassDecl1, tcClassDecls2, tcMethodBind, badMethodErr ) where

#include "HsVersions.h"

import HsSyn		( HsDecl(..), ClassDecl(..), Sig(..), MonoBinds(..),
			  InPat(..),
			  andMonoBinds, collectMonoBinders,
			  getTyVarName
			)
import HsPragmas	( ClassPragmas(..) )
import BasicTypes	( NewOrData(..), TopLevelFlag(..), RecFlag(..) )
import RnHsSyn		( RenamedClassDecl(..), RenamedClassPragmas(..),
			  RenamedClassOpSig(..), RenamedMonoBinds,
			  RenamedGenPragmas(..), RenamedContext(..), RenamedHsDecl
			)
import TcHsSyn		( TcHsBinds, TcMonoBinds, TcExpr,
			  mkHsTyApp, mkHsTyLam, mkHsDictApp, mkHsDictLam, tcIdType )

import Inst		( Inst, InstOrigin(..), LIE, emptyLIE, plusLIE, newDicts, newMethod )
import TcEnv		( TcIdOcc(..), newLocalIds, tcAddImportedIdInfo,
			  tcLookupClass, tcLookupTyVar, 
			  tcExtendGlobalTyVars )
import TcBinds		( tcBindWithSigs, checkSigTyVars, sigCtxt, sigThetaCtxt, TcSigInfo(..) )
import TcKind		( unifyKinds, TcKind )
import TcMonad
import TcMonoType	( tcHsType, tcContext )
import TcSimplify	( tcSimplifyAndCheck )
import TcType		( TcType, TcTyVar, TcTyVarSet, tcInstSigTyVars, 
			  zonkSigTyVar, tcInstSigTcType
			)
import PragmaInfo	( PragmaInfo(..) )

import Bag		( bagToList, unionManyBags )
import Class		( mkClass, classBigSig, Class )
import CmdLineOpts      ( opt_PprUserLength, opt_GlasgowExts )
import Id		( Id, StrictnessMark(..),
			  mkSuperDictSelId, mkMethodSelId, 
			  mkDefaultMethodId, getIdUnfolding, mkDataCon, 
			  idType
			)
import CoreUnfold	( getUnfoldingTemplate )
import IdInfo
import Name		( Name, isLocallyDefined, moduleString, getSrcLoc, 
			  OccName, nameOccName,
			  nameString, NamedThing(..) )
import Outputable
import SrcLoc		( mkGeneratedSrcLoc )
import Type		( mkFunTy, mkTyVarTy, mkTyVarTys, mkDictTy, splitRhoTy,
			  mkForAllTy, mkSigmaTy, splitSigmaTy, mkForAllTys, Type, ThetaType
			)
import TysWiredIn	( stringTy )
import TyVar		( unitTyVarSet, tyVarSetToList, mkTyVarSet, tyVarKind, TyVar )
import TyCon		( mkDataTyCon )
import Kind		( mkBoxedTypeKind, mkArrowKind )
import Unique		( Unique, Uniquable(..) )
import Util
import Maybes		( assocMaybe, maybeToBool )


-- import TcPragmas	( tcGenPragmas, tcClassOpPragmas )
tcGenPragmas ty id ps = returnNF_Tc noIdInfo
tcClassOpPragmas ty sel def spec ps = returnNF_Tc (noIdInfo `addSpecInfo` spec, 
						   noIdInfo)
\end{code}



Dictionary handling
~~~~~~~~~~~~~~~~~~~
Every class implicitly declares a new data type, corresponding to dictionaries
of that class. So, for example:

	class (D a) => C a where
	  op1 :: a -> a
	  op2 :: forall b. Ord b => a -> b -> b

would implicitly declare

	data CDict a = CDict (D a)	
			     (a -> a)
			     (forall b. Ord b => a -> b -> b)

(We could use a record decl, but that means changing more of the existing apparatus.
One step at at time!)

For classes with just one superclass+method, we use a newtype decl instead:

	class C a where
	  op :: forallb. a -> b -> b

generates

	newtype CDict a = CDict (forall b. a -> b -> b)

Now DictTy in Type is just a form of type synomym: 
	DictTy c t = TyConTy CDict `AppTy` t

Death to "ExpandingDicts".


\begin{code}
tcClassDecl1 rec_env rec_inst_mapper
      	     (ClassDecl context class_name
			tyvar_names class_sigs def_methods pragmas 
			tycon_name datacon_name src_loc)
  = tcAddSrcLoc src_loc	$
    tcAddErrCtxt (classDeclCtxt class_name) $

        -- CHECK ARITY 1 FOR HASKELL 1.4
    checkTc (opt_GlasgowExts || length tyvar_names == 1)
	    (classArityErr class_name)		`thenTc_`

	-- LOOK THINGS UP IN THE ENVIRONMENT
    tcLookupClass class_name			`thenTc` \ (class_kinds, rec_class) ->
    mapAndUnzipNF_Tc (tcLookupTyVar . getTyVarName) tyvar_names
						`thenNF_Tc` \ (tyvar_kinds, rec_tyvars) ->

	-- FORCE THE CLASS AND ITS TYVAR TO HAVE SAME KIND
    unifyKinds class_kinds tyvar_kinds	`thenTc_`

	-- CHECK THE CONTEXT
    tcClassContext rec_class rec_tyvars context pragmas	
						`thenTc` \ (sc_theta, sc_tys, sc_sel_ids) ->

	-- CHECK THE CLASS SIGNATURES,
    mapTc (tcClassSig rec_env rec_class rec_tyvars) class_sigs
						`thenTc` \ sig_stuff ->

	-- MAKE THE CLASS OBJECT ITSELF
    let
	(op_tys, op_sel_ids, defm_ids) = unzip3 sig_stuff
	rec_class_inst_env = rec_inst_mapper rec_class
	clas = mkClass (getName class_name) rec_tyvars
		       sc_theta sc_sel_ids op_sel_ids defm_ids
		       tycon
		       rec_class_inst_env

	dict_component_tys = sc_tys ++ op_tys
 	new_or_data = case dict_component_tys of
			[_]   -> NewType
			other -> DataType

        dict_con_id = mkDataCon datacon_name
			   [NotMarkedStrict | _ <- dict_component_tys]
			   [{- No labelled fields -}]
		      	   rec_tyvars
		      	   [{-No context-}]
			   [{-No existential tyvars-}] [{-Or context-}]
			   dict_component_tys
		      	   tycon

	tycon = mkDataTyCon tycon_name
			    (foldr (mkArrowKind . tyVarKind) mkBoxedTypeKind rec_tyvars)
			    rec_tyvars
			    []			-- No context
			    [dict_con_id]	-- Constructors
			    []			-- No derivings
			    (Just clas)		-- Yes!  It's a dictionary 
			    new_or_data
			    NonRecursive
    in
    returnTc clas
\end{code}


\begin{code}
tcClassContext :: Class -> [TyVar]
	       -> RenamedContext 	-- class context
	       -> RenamedClassPragmas	-- pragmas for superclasses  
	       -> TcM s (ThetaType,	-- the superclass context
			 [Type],	-- types of the superclass dictionaries
		         [Id])  	-- superclass selector Ids

tcClassContext rec_class rec_tyvars context pragmas
  = 	-- Check the context.
	-- The renamer has already checked that the context mentions
	-- only the type variable of the class decl.
    tcContext context			`thenTc` \ sc_theta ->
    let
       sc_tys = [mkDictTy sc tys | (sc,tys) <- sc_theta]
    in

	-- Make super-class selector ids
    mapTc mk_super_id sc_theta		`thenTc` \ sc_sel_ids ->

	-- Done
    returnTc (sc_theta, sc_tys, sc_sel_ids)

  where
    rec_tyvar_tys = mkTyVarTys rec_tyvars

    mk_super_id (super_class, tys)
        = tcGetUnique			`thenNF_Tc` \ uniq ->
	  let
		ty = mkForAllTys rec_tyvars $
		     mkFunTy (mkDictTy rec_class rec_tyvar_tys) (mkDictTy super_class tys)
	  in
	  returnTc (mkSuperDictSelId uniq rec_class super_class ty)


tcClassSig :: TcEnv s			-- Knot tying only!
	   -> Class	    		-- ...ditto...
	   -> [TyVar]		 	-- The class type variable, used for error check only
	   -> RenamedClassOpSig
	   -> TcM s (Type,		-- Type of the method
		     Id,		-- selector id
		     Maybe Id)		-- default-method ids

tcClassSig rec_env rec_clas rec_clas_tyvars
	   (ClassOpSig op_name maybe_dm_name
		       op_ty
		       src_loc)
  = tcAddSrcLoc src_loc $

	-- Check the type signature.  NB that the envt *already has*
	-- bindings for the type variables; see comments in TcTyAndClassDcls.

    -- NB: Renamer checks that the class type variable is mentioned in local_ty,
    -- and that it is not constrained by theta
    tcHsType op_ty				`thenTc` \ local_ty ->
    let
	global_ty   = mkSigmaTy rec_clas_tyvars 
			        [(rec_clas, mkTyVarTys rec_clas_tyvars)]
			        local_ty
    in

	-- Build the selector id and default method id
    let
	sel_id      = mkMethodSelId op_name rec_clas global_ty
	maybe_dm_id = case maybe_dm_name of
			   Nothing      -> Nothing
			   Just dm_name -> let 
					     dm_id = mkDefaultMethodId dm_name rec_clas global_ty
					   in
					   Just (tcAddImportedIdInfo rec_env dm_id)
    in
    returnTc (local_ty, sel_id, maybe_dm_id)
\end{code}


%************************************************************************
%*									*
\subsection[ClassDcl-pass2]{Class decls pass 2: default methods}
%*									*
%************************************************************************

The purpose of pass 2 is
\begin{enumerate}
\item
to beat on the explicitly-provided default-method decls (if any),
using them to produce a complete set of default-method decls.
(Omitted ones elicit an error message.)
\item
to produce a definition for the selector function for each method
and superclass dictionary.
\end{enumerate}

Pass~2 only applies to locally-defined class declarations.

The function @tcClassDecls2@ just arranges to apply @tcClassDecl2@ to
each local class decl.

\begin{code}
tcClassDecls2 :: [RenamedHsDecl]
	      -> NF_TcM s (LIE s, TcMonoBinds s)

tcClassDecls2 decls
  = foldr combine
	  (returnNF_Tc (emptyLIE, EmptyMonoBinds))
	  [tcClassDecl2 cls_decl | ClD cls_decl <- decls]
  where
    combine tc1 tc2 = tc1 `thenNF_Tc` \ (lie1, binds1) ->
		      tc2 `thenNF_Tc` \ (lie2, binds2) ->
		      returnNF_Tc (lie1 `plusLIE` lie2,
				   binds1 `AndMonoBinds` binds2)
\end{code}

@tcClassDecl2@ is the business end of things.

\begin{code}
tcClassDecl2 :: RenamedClassDecl	-- The class declaration
	     -> NF_TcM s (LIE s, TcMonoBinds s)

tcClassDecl2 (ClassDecl context class_name
			tyvar_names class_sigs default_binds pragmas _ _ src_loc)

  | not (isLocallyDefined class_name)
  = returnNF_Tc (emptyLIE, EmptyMonoBinds)

  | otherwise	-- It is locally defined
  = recoverNF_Tc (returnNF_Tc (emptyLIE, EmptyMonoBinds)) $ 
    tcAddSrcLoc src_loc		     		          $

	-- Get the relevant class
    tcLookupClass class_name		`thenTc` \ (_, clas) ->
    let
	(tyvars, sc_theta, sc_sel_ids, op_sel_ids, defm_ids) = classBigSig clas

	-- The selector binds are already in the selector Id's unfoldings
	sel_binds = [ CoreMonoBind (RealId sel_id) (getUnfoldingTemplate (getIdUnfolding sel_id))
		    | sel_id <- sc_sel_ids ++ op_sel_ids, 
		      isLocallyDefined sel_id
		    ]

    	final_sel_binds = andMonoBinds sel_binds
    in
	-- Generate bindings for the default methods
    tcDefaultMethodBinds clas default_binds		`thenTc` \ (const_insts, meth_binds) ->

    returnTc (const_insts, 
	      final_sel_binds `AndMonoBinds` meth_binds)
\end{code}

%************************************************************************
%*									*
\subsection[Default methods]{Default methods}
%*									*
%************************************************************************

The default methods for a class are each passed a dictionary for the
class, so that they get access to the other methods at the same type.
So, given the class decl
\begin{verbatim}
class Foo a where
	op1 :: a -> Bool
	op2 :: Ord b => a -> b -> b -> b

	op1 x = True
	op2 x y z = if (op1 x) && (y < z) then y else z
\end{verbatim}
we get the default methods:
\begin{verbatim}
defm.Foo.op1 :: forall a. Foo a => a -> Bool
defm.Foo.op1 = /\a -> \dfoo -> \x -> True

====================== OLD ==================
\begin{verbatim}
defm.Foo.op2 :: forall a, b. (Foo a, Ord b) => a -> b -> b -> b
defm.Foo.op2 = /\ a b -> \ dfoo dord -> \x y z ->
		  if (op1 a dfoo x) && (< b dord y z) then y else z
\end{verbatim}
Notice that, like all ids, the foralls of defm.Foo.op2 are at the top.
====================== END OF OLD ===================

NEW:
\begin{verbatim}
defm.Foo.op2 :: forall a. Foo a => forall b. Ord b => a -> b -> b -> b
defm.Foo.op2 = /\ a -> \ dfoo -> /\ b -> \ dord -> \x y z ->
		  if (op1 a dfoo x) && (< b dord y z) then y else z
\end{verbatim}


When we come across an instance decl, we may need to use the default
methods:
\begin{verbatim}
instance Foo Int where {}
\end{verbatim}
gives
\begin{verbatim}
const.Foo.Int.op1 :: Int -> Bool
const.Foo.Int.op1 = defm.Foo.op1 Int dfun.Foo.Int

const.Foo.Int.op2 :: forall b. Ord b => Int -> b -> b -> b
const.Foo.Int.op2 = defm.Foo.op2 Int dfun.Foo.Int

dfun.Foo.Int :: Foo Int
dfun.Foo.Int = (const.Foo.Int.op1, const.Foo.Int.op2)
\end{verbatim}
Notice that, as with method selectors above, we assume that dictionary
application is curried, so there's no need to mention the Ord dictionary
in const.Foo.Int.op2 (or the type variable).

\begin{verbatim}
instance Foo a => Foo [a] where {}

dfun.Foo.List :: forall a. Foo a -> Foo [a]
dfun.Foo.List
  = /\ a -> \ dfoo_a ->
    let rec
	op1 = defm.Foo.op1 [a] dfoo_list
	op2 = defm.Foo.op2 [a] dfoo_list
	dfoo_list = (op1, op2)
    in
	dfoo_list
\end{verbatim}

\begin{code}
tcDefaultMethodBinds
	:: Class
	-> RenamedMonoBinds
	-> TcM s (LIE s, TcMonoBinds s)

tcDefaultMethodBinds clas default_binds
  = 	-- Construct suitable signatures
    tcInstSigTyVars tyvars		`thenNF_Tc` \ (clas_tyvars, inst_tys, inst_env) ->

	-- Typecheck the default bindings
    let
	tc_dm meth_bind
	  | not (maybeToBool maybe_stuff)
	  =	-- Binding for something that isn't in the class signature
	    failWithTc (badMethodErr bndr_name clas)

	  | otherwise
	  =	-- Normal case
	    tcMethodBind clas origin inst_tys clas_tyvars sel_id meth_bind
						`thenTc` \ (bind, insts, (_, local_dm_id)) ->
	    returnTc (bind, insts, (clas_tyvars, RealId dm_id, local_dm_id))
	  where
	    bndr_name  = case meth_bind of
				FunMonoBind name _ _ _		-> name
				PatMonoBind (VarPatIn name) _ _ -> name
				
	    maybe_stuff = assocMaybe assoc_list (nameOccName bndr_name)
	    assoc_list  = [ (getOccName sel_id, pair) 
			  | pair@(sel_id, dm_ie) <- op_sel_ids `zip` defm_ids
			  ]
	    Just (sel_id, Just dm_id) = maybe_stuff
		 -- We're looking at a default-method binding, so the dm_id
		 -- is sure to be there!  Hence the inner "Just".
    in	   
    mapAndUnzip3Tc tc_dm 
	(flatten default_binds [])		`thenTc` \ (defm_binds, insts_needed, abs_bind_stuff) ->

	-- Check the context
    newDicts origin [(clas,inst_tys)]		`thenNF_Tc` \ (this_dict, [this_dict_id]) ->
    let
	avail_insts = this_dict
    in
    tcAddErrCtxt (classDeclCtxt clas) $
    tcAddErrCtxtM (sigThetaCtxt avail_insts) $
    mapNF_Tc zonkSigTyVar clas_tyvars		`thenNF_Tc` \ clas_tyvars' ->
    tcSimplifyAndCheck (text "classDecl")
	(mkTyVarSet clas_tyvars')
	avail_insts
	(unionManyBags insts_needed)		`thenTc` \ (const_lie, dict_binds) ->

    let
	full_binds = AbsBinds
		 	clas_tyvars'
			[this_dict_id]
			abs_bind_stuff
			(dict_binds `AndMonoBinds` andMonoBinds defm_binds)
    in
    returnTc (const_lie, full_binds)

  where
    (tyvars, sc_theta, sc_sel_ids, op_sel_ids, defm_ids) = classBigSig clas
    origin = ClassDeclOrigin

    flatten EmptyMonoBinds rest	      = rest
    flatten (AndMonoBinds b1 b2) rest = flatten b1 (flatten b2 rest)
    flatten a_bind rest		      = a_bind : rest
\end{code}

@tcMethodBind@ is used to type-check both default-method and
instance-decl method declarations.  We must type-check methods one at a
time, because their signatures may have different contexts and
tyvar sets.

\begin{code}
tcMethodBind 
	:: Class
	-> InstOrigin s
	-> [TcType s]					-- Instance types
	-> [TcTyVar s]					-- Free variables of those instance types
							--  they'll be signature tyvars, and we
							--  want to check that they don't bound
	-> Id						-- The method selector
	-> RenamedMonoBinds				-- Method binding (just one)
	-> TcM s (TcMonoBinds s, LIE s, (LIE s, TcIdOcc s))

tcMethodBind clas origin inst_tys inst_tyvars sel_id meth_bind
 = tcAddSrcLoc src_loc	 		        $
   newMethod origin (RealId sel_id) inst_tys	`thenNF_Tc` \ meth@(_, TcId local_meth_id) ->
   tcInstSigTcType (idType local_meth_id)	`thenNF_Tc` \ (tyvars', rho_ty') ->
   let
	(theta', tau')  = splitRhoTy rho_ty'
	sig_info        = TySigInfo bndr_name local_meth_id tyvars' theta' tau' src_loc
   in
   tcExtendGlobalTyVars inst_tyvars (
     tcAddErrCtxt (methodCtxt sel_id)		$
     tcBindWithSigs NotTopLevel [bndr_name] meth_bind [sig_info]
		    NonRecursive (\_ -> NoPragmaInfo)	
   )							`thenTc` \ (binds, insts, _) ->

	-- Now check that the instance type variables
	-- (or, in the case of a class decl, the class tyvars)
	-- have not been unified with anything in the environment
   tcAddErrCtxt (monoCtxt sel_id) (
     tcAddErrCtxt (sigCtxt sel_id) $
     checkSigTyVars inst_tyvars (idType local_meth_id)
   )							`thenTc_` 

   returnTc (binds, insts, meth)
 where
   (bndr_name, src_loc) = case meth_bind of
				FunMonoBind name _ _ loc	  -> (name, loc)
				PatMonoBind (VarPatIn name) _ loc -> (name, loc)
\end{code}

Contexts and errors
~~~~~~~~~~~~~~~~~~~
\begin{code}
classArityErr class_name
  = ptext SLIT("Too many parameters for class") <+> quotes (ppr class_name)

classDeclCtxt class_name
  = ptext SLIT("In the class declaration for") <+> quotes (ppr class_name)

methodCtxt sel_id
  = ptext SLIT("In the definition for method") <+> quotes (ppr sel_id)

monoCtxt sel_id
  = sep [ptext SLIT("Probable cause: the right hand side of") <+> quotes (ppr sel_id),
         nest 4 (ptext SLIT("mentions a top-level variable subject to the dreaded monomorphism restriction"))
    ]

badMethodErr bndr clas
  = hsep [ptext SLIT("Class"), quotes (ppr clas), 
	  ptext SLIT("does not have a method"), quotes (ppr bndr)]
\end{code}
