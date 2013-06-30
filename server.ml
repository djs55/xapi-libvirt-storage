(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Xcp_service
open Common
open Xml

let driver = "libvirt"
let name = Filename.basename Sys.argv.(0)
let description = "xapi libvirt storage connector"
let vendor = "Citrix"
let copyright = "Citrix Inc"
let required_api_version = "2.0"
let features = [
  "VDI_CREATE", 0L;
  "VDI_DELETE", 0L;
  "VDI_ATTACH", 0L;
  "VDI_DETACH", 0L;
  "VDI_ACTIVATE", 0L;
  "VDI_DEACTIVATE", 0L;
]
let _xml  = "xml"
let _uri  = "uri"
let configuration = [
   _xml, "XML fragment describing the storage pool configuration";
   _uri, "URI of the hypervisor to use";
]

module C = Libvirt.Connect
module P = Libvirt.Pool
module V = Libvirt.Volume

let conn = ref None

let get_connection ?name () = match !conn with
  | None ->
    let c = C.connect ?name () in
    conn := Some c;
    c
  | Some c -> c

type sr = {
  pool: Libvirt.rw P.t;
}

open Storage_interface

module Attached_srs = struct
  let table = Hashtbl.create 16
  let get id =
    if not(Hashtbl.mem table id)
    then raise (Sr_not_attached id)
    else Hashtbl.find table id
  let put id sr =
    if Hashtbl.mem table id
    then raise (Sr_attached id)
    else Hashtbl.replace table id sr
  let remove id =
    if not(Hashtbl.mem table id)
    then raise (Sr_not_attached id)
    else Hashtbl.remove table id
  let num_attached () = Hashtbl.fold (fun _ _ acc -> acc + 1) table 0
end

let report_libvirt_error f x =
  try
    f x
  with Libvirt.Virterror t ->
    error "from libvirt: %s" (Libvirt.Virterror.to_string t);
    raise (Backend_error ("libvirt", [Libvirt.Virterror.to_string t]))


module Implementation = struct
  type context = unit

  module Query = struct
    let query ctx ~dbg = {
        driver;
        name;
        description;
        vendor;
        copyright;
        version = Version.version;
        required_api_version;
        features;
        configuration;
    }

    let diagnostics ctx ~dbg = "Not available"
  end
  module DP = struct include Storage_skeleton.DP end
  module VDI = struct
    (* The following are all not implemented: *)
    open Storage_skeleton.VDI
    let clone = clone
    let snapshot = snapshot
    let epoch_begin = epoch_begin
    let epoch_end = epoch_end
    let get_url = get_url
    let set_persistent = set_persistent
    let compose = compose
    let similar_content = similar_content
    let add_to_sm_config = add_to_sm_config
    let remove_from_sm_config = remove_from_sm_config
    let set_content_id = set_content_id
    let get_by_name = get_by_name

    let vdi_path_of key =
      let c = get_connection () in
      let v = V.lookup_by_key c key in
      let xml = V.get_xml_desc (V.const v) in
      read_xml_path volume_target_path xml 

    let vdi_vol_of key =
      let c = get_connection () in
      let v = V.lookup_by_key c key in
      V.get_name (V.const v)

    let vdi_info_of_name pool name =
        try
          let v = V.lookup_by_name pool name in
          let info = V.get_info v in
          let key = V.get_key v in
          Some {
              vdi = key;
              content_id = "";
              name_label = name;
              name_description = "";
              ty = "user";
              metadata_of_pool = "";
              is_a_snapshot = false;
              snapshot_time = iso8601_of_float 0.;
              snapshot_of = "";
              read_only = false;
              virtual_size = info.V.capacity;
              physical_utilisation = info.V.allocation;
              sm_config = [];
              persistent = true;
          }
        with Libvirt.Virterror t ->
          error "Error while looking up volume: %s: %s" name (Libvirt.Virterror.to_string t);
          None
        | e ->
          error "Error while looking up volume: %s: %s" name (Printexc.to_string e);
          None

    let choose_filename sr name_label =
      let pool = Libvirt.Pool.const sr.pool in
      let count = Libvirt.Pool.num_of_volumes pool in
      let existing = Array.to_list (Libvirt.Pool.list_volumes pool count) in

      if not(List.mem name_label existing)
      then name_label
      else
        let stem = name_label ^ "." in
        let with_common_prefix = List.filter (startswith stem) existing in
        let suffixes = List.map (remove_prefix stem) with_common_prefix in
        let highest_number = List.fold_left (fun acc suffix ->
          let this = try int_of_string suffix with _ -> 0 in
          max acc this) 0 suffixes in
        stem ^ (string_of_int (highest_number + 1))


    let create ctx ~dbg ~sr ~vdi_info =
      let sr = Attached_srs.get sr in
      let name = vdi_info.name_label ^ ".img" in
      (* If this volume already exists, make a different name which is
         unique. NB this is not concurrency-safe *)
      let name =
        if vdi_info_of_name (P.const sr.pool) name = None
        then name
        else
          let name' = choose_filename sr name in
          info "Rewriting name from %s to %s to guarantee uniqueness" name name';
          name' in 

      let xml = Printf.sprintf "
        <volume>
          <name>%s</name>
          <capacity unit=\"B\">%Ld</capacity>
        </volume>
      " name vdi_info.virtual_size in
      report_libvirt_error (Libvirt.Volume.create_xml sr.pool) xml;
      match vdi_info_of_name (P.const sr.pool) name with
      | Some x -> x
      | None ->
        failwith "Failed to find volume in storage pool: create silently failed?"

    let destroy ctx ~dbg ~sr ~vdi =
      let c = get_connection () in
      let v = V.lookup_by_path c vdi in
      report_libvirt_error (V.delete v) V.Normal

    let stat ctx ~dbg ~sr ~vdi = assert false
    let attach ctx ~dbg ~dp ~sr ~vdi ~read_write =
      let path = vdi_path_of vdi in
      {
        params = path;
        xenstore_data = [
          "type", "rbd";
          "name", "rbd:" ^ vdi; (* XXX some versions of qemu require this hack *)
        ]
      }
    let detach ctx ~dbg ~dp ~sr ~vdi =
      let _ = vdi_path_of vdi in
      ()
    let activate ctx ~dbg ~dp ~sr ~vdi = ()
    let deactivate ctx ~dbg ~dp ~sr ~vdi = ()
  end
  module SR = struct
    open Storage_skeleton.SR
    let list = list
    let scan ctx ~dbg ~sr =
       let sr = Attached_srs.get sr in
       let pool = Libvirt.Pool.const sr.pool in
       let count = Libvirt.Pool.num_of_volumes pool in
       report_libvirt_error (Libvirt.Pool.list_volumes pool) count
       |> Array.to_list
       |> List.map (VDI.vdi_info_of_name pool)
       |> List.fold_left (fun acc x -> match x with
             | None -> acc
             | Some x -> x :: acc) []

    let destroy = destroy
    let reset = reset
    let detach ctx ~dbg ~sr =
       Attached_srs.remove sr;
       if Attached_srs.num_attached () = 0
       then match !conn with
       | Some c ->
            C.close c;
            conn := None
       | None -> ()

    let optional device_config key =
      if List.mem_assoc key device_config
      then Some (List.assoc key device_config)
      else None
    let require device_config key =
      if not(List.mem_assoc key device_config) then begin
        error "Required device_config:%s not present" key;
        raise (Missing_configuration_parameter key)
      end else List.assoc key device_config


    let attach ctx ~dbg ~sr ~device_config =
       let xml = require device_config _xml in
       let uri = optional device_config _uri in
       let c = get_connection ?name:uri () in
       let name = read_xml_path name_pool xml in
       let pool =
         try
           P.lookup_by_name c name
         with e ->
           info "Failed to discover existing storage pool '%s': attempting to create" name;
           report_libvirt_error (Libvirt.Pool.create_xml c) xml in
       Attached_srs.put sr { pool }

    let create ctx ~dbg ~sr ~device_config ~physical_size =
       (* Sometimes an active storage pool disappears from libvirt's list.
          We make 'attach' mean 'attach if existing, re-create if missing' *)
       attach ctx ~dbg ~sr ~device_config
  end
  module UPDATES = struct include Storage_skeleton.UPDATES end
  module TASK = struct include Storage_skeleton.TASK end
  module Policy = struct include Storage_skeleton.Policy end
  module DATA = struct include Storage_skeleton.DATA end
  let get_by_name = Storage_skeleton.get_by_name
end

module Server = Storage_interface.Server(Implementation)

