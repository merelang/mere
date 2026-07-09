(* Package installer for the v0.2 package system (design doc: project
   notes 61). Reads a `mere.toml` manifest, fetches each dependency from
   git (optionally a monorepo `subdir`) at a pinned `rev`, and populates
   `.mere_modules/<name>/` so the existing walk-up resolver finds it.

   Key rule (from the mere-notes dogfood, project OPEN_QUESTIONS Q-013):
   packages are installed under their *bare* directory name so that
   `.mere_modules/` mirrors the source layout — that keeps contrib's
   cross-package relative imports (`import "../log/log.mere"`) resolving.
   The installer follows those relative imports to pull transitive
   cross-package dependencies automatically.

   This is pure tooling: it needs no change to the language or the
   resolver. It shells out to `git` (fetch), `cp`/`mkdir` (copy); file
   walking and hashing use the OCaml stdlib. *)

exception Install_error of string

let err fmt = Printf.ksprintf (fun s -> raise (Install_error s)) fmt

(* ---- tiny helpers ------------------------------------------------------ *)

let read_file path = In_channel.with_open_text path In_channel.input_all

let sh cmd =
  let code = Sys.command cmd in
  if code <> 0 then err "command failed (exit %d): %s" code cmd

let sh_read cmd =
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  (match Unix.close_process_in ic with
   | Unix.WEXITED 0 -> ()
   | _ -> err "command failed: %s" cmd);
  String.trim out

let q = Filename.quote

(* Normalise a slash path, resolving `.` and `..` segments textually. *)
let normalize (p : string) : string =
  let segs = String.split_on_char '/' p in
  let out =
    List.fold_left
      (fun acc s ->
        match s with
        | "" | "." -> acc
        | ".." -> (match acc with _ :: tl -> tl | [] -> [])
        | _ -> s :: acc)
      [] segs
  in
  String.concat "/" (List.rev out)

(* Recursively list files under [dir], returning paths relative to it. *)
let rec walk_rel dir prefix =
  Sys.readdir dir
  |> Array.to_list
  |> List.sort compare
  |> List.concat_map (fun name ->
         let full = Filename.concat dir name in
         let rel = if prefix = "" then name else prefix ^ "/" ^ name in
         if Sys.is_directory full then walk_rel full rel else [ rel ])

(* ---- manifest parsing (minimal, mere.toml subset) --------------------- *)

type dep = { name : string; git : string; subdir : string option; rev : string }
type manifest = { pkg_name : string; pkg_version : string; deps : dep list }

(* Pull `key = "value"` pairs out of an inline table body like
   `git = "...", subdir = "contrib/http", rev = "abc"`. *)
let parse_inline_table (body : string) : (string * string) list =
  let re = Str.regexp "\\([a-z_]+\\)[ \t]*=[ \t]*\"\\([^\"]*\\)\"" in
  let rec loop pos acc =
    match Str.search_forward re body pos with
    | i ->
      let k = Str.matched_group 1 body and v = Str.matched_group 2 body in
      loop (i + String.length (Str.matched_string body)) ((k, v) :: acc)
    | exception Not_found -> List.rev acc
  in
  loop 0 []

let strip_comment line =
  match String.index_opt line '#' with
  | Some i -> String.sub line 0 i
  | None -> line

let parse_manifest (content : string) : manifest =
  let lines = String.split_on_char '\n' content in
  let section = ref "" in
  let pkg_name = ref "" and pkg_version = ref "0.0.0" in
  let deps = ref [] in
  let simple_kv = Str.regexp "^[ \t]*\\([a-z_]+\\)[ \t]*=[ \t]*\"\\([^\"]*\\)\"" in
  let dep_line = Str.regexp "^[ \t]*\\([A-Za-z0-9_-]+\\)[ \t]*=[ \t]*{\\(.*\\)}" in
  List.iter
    (fun raw ->
      let line = strip_comment raw in
      let t = String.trim line in
      if t = "" then ()
      else if String.length t >= 2 && t.[0] = '[' then
        section := String.sub t 1 (String.length t - 2)
      else if !section = "dependencies" && Str.string_match dep_line line 0 then begin
        let name = Str.matched_group 1 line in
        let body = Str.matched_group 2 line in
        let kv = parse_inline_table body in
        let get k = List.assoc_opt k kv in
        match get "git", get "rev" with
        | Some git, Some rev ->
          deps := { name; git; subdir = get "subdir"; rev } :: !deps
        | _ -> err "dependency %S needs both `git` and `rev`" name
      end
      else if !section = "package" && Str.string_match simple_kv line 0 then begin
        let k = Str.matched_group 1 line and v = Str.matched_group 2 line in
        if k = "name" then pkg_name := v
        else if k = "version" then pkg_version := v
      end)
    lines;
  { pkg_name = !pkg_name; pkg_version = !pkg_version; deps = List.rev !deps }

(* ---- fetch + copy ------------------------------------------------------ *)

let cache_root () =
  match Sys.getenv_opt "HOME" with
  | Some h -> Filename.concat (Filename.concat h ".mere") "cache"
  | None -> Filename.concat (Filename.get_temp_dir_name ()) "mere-cache"

(* Clone (once, cached) [git] and check out [rev]. Returns (checkout dir,
   resolved full commit sha). *)
let fetch git rev =
  let key = Digest.to_hex (Digest.string (git ^ "@" ^ rev)) in
  let dir = Filename.concat (cache_root ()) key in
  if not (Sys.file_exists dir) then begin
    sh (Printf.sprintf "mkdir -p %s" (q (cache_root ())));
    sh (Printf.sprintf "git clone --quiet %s %s" (q git) (q dir))
  end;
  sh (Printf.sprintf "git -C %s -c advice.detachedHead=false checkout --quiet %s"
        (q dir) (q rev));
  let sha = sh_read (Printf.sprintf "git -C %s rev-parse HEAD" (q dir)) in
  (dir, sha)

let copy_tree src dst =
  sh (Printf.sprintf "rm -rf %s" (q dst));
  sh (Printf.sprintf "mkdir -p %s" (q dst));
  (* `cp -R src/. dst` copies contents, not the dir itself. *)
  sh (Printf.sprintf "cp -R %s/. %s" (q src) (q dst))

(* Content hash of an installed package dir: md5 over sorted
   (relpath, bytes) pairs, so re-installs are verifiable. *)
let dir_hash dir =
  let files = walk_rel dir "" in
  let buf = Buffer.create 4096 in
  List.iter
    (fun rel ->
      Buffer.add_string buf rel;
      Buffer.add_char buf '\000';
      Buffer.add_string buf (read_file (Filename.concat dir rel));
      Buffer.add_char buf '\000')
    files;
  "md5:" ^ Digest.to_hex (Digest.string (Buffer.contents buf))

(* Scan a package's .mere files for cross-package relative imports
   (`../X/…`, `../../X/…`) and return the set of referenced package names
   together with the source subdir each resolves to inside the clone. *)
let import_re = Str.regexp "^[ \t]*import[ \t]+\"\\(\\(\\.\\./\\)+[^\"]*\\)\""

let scan_cross_deps ~pkg_dir ~pkg_subdir : (string * string) list =
  let files = List.filter (fun f -> Filename.check_suffix f ".mere") (walk_rel pkg_dir "") in
  let acc = Hashtbl.create 16 in
  List.iter
    (fun rel ->
      let content = read_file (Filename.concat pkg_dir rel) in
      List.iter
        (fun line ->
          if Str.string_match import_re line 0 then begin
            let imp = Str.matched_group 1 line in
            (* Resolve the import relative to this file's location inside
               the clone, e.g. contrib/http/access_log.mere + ../log/log.mere
               -> contrib/log/log.mere. *)
            let file_dir = Filename.dirname (Filename.concat pkg_subdir rel) in
            let resolved = normalize (file_dir ^ "/" ^ imp) in
            (* Package = first two path segments (contrib/<name>). *)
            match String.split_on_char '/' resolved with
            | root :: name :: _ ->
              let subdir = root ^ "/" ^ name in
              if not (Hashtbl.mem acc name) then Hashtbl.add acc name subdir
            | _ -> ()
          end)
        (String.split_on_char '\n' content))
    files;
  Hashtbl.fold (fun k v a -> (k, v) :: a) acc []

(* ---- lockfile ---------------------------------------------------------- *)

type lock_entry = { l_name : string; l_git : string; l_subdir : string option;
                    l_rev : string; l_hash : string }

let write_lock ~root (entries : lock_entry list) =
  let entries = List.sort (fun a b -> compare a.l_name b.l_name) entries in
  let buf = Buffer.create 1024 in
  Buffer.add_string buf "# mere.lock — generated by `mere install`; do not edit.\n";
  List.iter
    (fun e ->
      Buffer.add_string buf "\n[[package]]\n";
      Buffer.add_string buf (Printf.sprintf "name = %S\n" e.l_name);
      Buffer.add_string buf (Printf.sprintf "git = %S\n" e.l_git);
      (match e.l_subdir with
       | Some s -> Buffer.add_string buf (Printf.sprintf "subdir = %S\n" s)
       | None -> ());
      Buffer.add_string buf (Printf.sprintf "rev = %S\n" e.l_rev);
      Buffer.add_string buf (Printf.sprintf "hash = %S\n" e.l_hash))
    entries;
  Out_channel.with_open_text (Filename.concat root "mere.lock")
    (fun oc -> Out_channel.output_string oc (Buffer.contents buf))

(* ---- top-level install ------------------------------------------------- *)

let install ~root =
  let manifest_path = Filename.concat root "mere.toml" in
  if not (Sys.file_exists manifest_path) then
    err "no mere.toml in %s" root;
  let m = parse_manifest (read_file manifest_path) in
  let modules_dir = Filename.concat root ".mere_modules" in
  sh (Printf.sprintf "mkdir -p %s" (q modules_dir));
  let installed = Hashtbl.create 16 in
  let entries = ref [] in
  (* Worklist of packages to install: (name, git, subdir option, rev). *)
  let queue = Queue.create () in
  List.iter (fun d -> Queue.push (d.name, d.git, d.subdir, d.rev) queue) m.deps;
  while not (Queue.is_empty queue) do
    let (name, git, subdir, rev) = Queue.pop queue in
    if not (Hashtbl.mem installed name) then begin
      Hashtbl.add installed name ();
      let (clone, sha) = fetch git rev in
      let src = match subdir with
        | Some s -> Filename.concat clone s
        | None -> clone in
      if not (Sys.file_exists src) then
        err "package %S: subdir %s not found in %s"
          name (Option.value ~default:"." subdir) git;
      let dst = Filename.concat modules_dir name in
      copy_tree src dst;
      Printf.printf "  installed %s (%s%s @ %s)\n" name git
        (match subdir with Some s -> " " ^ s | None -> "")
        (String.sub sha 0 (min 8 (String.length sha)));
      entries := { l_name = name; l_git = git; l_subdir = subdir;
                   l_rev = sha; l_hash = dir_hash dst } :: !entries;
      (* Follow cross-package relative imports (transitive deps). Their
         source subdir is a sibling under the same clone/repo. *)
      (match subdir with
       | Some pkg_subdir ->
         List.iter
           (fun (dep_name, dep_subdir) ->
             if not (Hashtbl.mem installed dep_name) then
               Queue.push (dep_name, git, Some dep_subdir, rev) queue)
           (scan_cross_deps ~pkg_dir:dst ~pkg_subdir)
       | None -> ())
    end
  done;
  write_lock ~root !entries;
  Printf.printf "wrote %s (%d packages)\n"
    (Filename.concat root "mere.lock") (List.length !entries)
