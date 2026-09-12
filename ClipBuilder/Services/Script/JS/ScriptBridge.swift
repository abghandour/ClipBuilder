import Foundation
import MCP

@MainActor
enum ScriptBridge {
    static func bootstrap(params: Data, name: String, mode: String, tools: BuilderTools) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let catalog = String(decoding: try encoder.encode(BuilderCommandCatalog.operations), as: UTF8.self)
        let metadata = String(decoding: try encoder.encode(["name": name, "mode": mode]), as: UTF8.self)
        let ensures = tools.definitions.map(\.name).filter { $0.hasPrefix("ensure_") }
        let paramsJSON = String(decoding: try encoder.encode(String(decoding: params, as: UTF8.self)), as: UTF8.self)
        let ensureJSON = String(decoding: try encoder.encode(ensures), as: UTF8.self)
        return """
        (function(host, catalog, values, metadata, ensures) {
        "use strict";
        const stringify = JSON.stringify, parse = JSON.parse, keys = Object.keys;
        const Number = globalThis.Number, String = globalThis.String, Set = globalThis.Set;
        const charCodeAt = Function.call.bind(String.prototype.charCodeAt);
        const setHas = Function.call.bind(Set.prototype.has), setAdd = Function.call.bind(Set.prototype.add);
        const setDelete = Function.call.bind(Set.prototype.delete);
        values=parse(values);
        const ownKeys = Reflect.ownKeys, proto = Object.getPrototypeOf;
        const own = Function.call.bind(Object.prototype.hasOwnProperty);
        const array = Array.isArray, finite = Number.isFinite, integer = Number.isInteger;
        const safeInteger = Number.isSafeInteger, freeze = Object.freeze;
        const define = Object.defineProperty, create = Object.create, NativeError = Error;
        const objectProto = Object.prototype, arrayProto = Array.prototype;
        const has = (o,k) => own(o,k);
        function fail(code, reason) {
            const error = new NativeError(reason); error.code = code; error.reason = reason; throw error;
        }
        function limit(reason) {
            host("__terminal", stringify({code:"limit",reason}));
            fail("limit", reason);
        }
        function bytes(s) {
            let n = 0;
            for (let i=0;i<s.length;i++) {
                const c=charCodeAt(s,i);
                if (c<128) n++; else if(c<2048) n+=2;
                else if(c>=0xD800 && c<=0xDBFF && i+1<s.length && charCodeAt(s,i+1)>=0xDC00 && charCodeAt(s,i+1)<=0xDFFF) {n+=4;i++;}
                else n+=3;
            }
            return n;
        }
        function encode(value, cap) {
            const seen = new Set();
            function copy(v, depth) {
                if(depth>32) limit("JSON depth exceeds 32.");
                if(v===null || typeof v==="string" || typeof v==="boolean") return v;
                if(typeof v==="number") {
                    if(!finite(v) || (integer(v) && !safeInteger(v))) fail("invalid_script","Non-finite or unsafe integer.");
                    return v;
                }
                if(typeof v!=="object") fail("invalid_script","Only JSON values are allowed.");
                if(setHas(seen,v)) fail("invalid_script","Cyclic JSON value.");
                const isArray=array(v), p=proto(v);
                if((isArray && p!==arrayProto) || (!isArray && p!==objectProto && p!==null))
                    fail("invalid_script","Non-JSON object.");
                setAdd(seen,v);
                const out=isArray?[]:create(null);
                const names=ownKeys(v);
                for(const key of names) {
                    if(typeof key!=="string") fail("invalid_script","Symbol keys are not JSON.");
                    if(isArray && key==="length") continue;
                    if(isArray && (!/^(0|[1-9][0-9]*)$/.test(key) || Number(key)>=v.length))
                        fail("invalid_script","Array properties are not JSON.");
                    out[key]=copy(v[key],depth+1);
                }
                if(isArray) {
                    for(let i=0;i<v.length;i++) if(!has(v,String(i))) fail("invalid_script","Array holes are not JSON.");
                }
                setDelete(seen,v); return out;
            }
            const text=stringify(copy(value,0));
            if(bytes(text)>cap) limit("JSON byte limit exceeded.");
            return text;
        }
        function object(v) {
            if(v===null || typeof v!=="object" || array(v)) fail("invalid_script","Expected an object.");
        }
        function only(v, allowed) {
            object(v);
            for(const k of keys(v)) if(!allowed.includes(k)) fail("invalid_script","Unknown field: "+k);
        }
        function options(v) {
            if(v===undefined) return {};
            v=parse(encode(v,1048576));
            only(v,["tolerate","bind"]);
            if(has(v,"tolerate") && typeof v.tolerate!=="boolean") fail("invalid_script","tolerate must be boolean.");
            if(has(v,"bind") && typeof v.bind!=="string") fail("invalid_script","bind must be a string.");
            return v;
        }
        function call(name,args,tolerate) {
            const result=parse(host(name,encode(args,1048576)));
            encode(result,1048576);
            if(result.error) fail(result.error.code,result.error.reason);
            const value=result.value;
            if(value && value.outcomes && !tolerate) {
                const refused=value.outcomes.find(o=>o.status==="refused");
                if(refused) fail(refused.code,refused.reason);
            }
            return value;
        }
        function step(s) {
            object(s);
            // Validate before lowering so discarded undefined/functions cannot escape.
            s=parse(encode(s,1048576));
            let command, bind;
            if(has(s,"command")) {
                only(s,["command","bind"]); command=s.command; bind=s.bind;
            } else {
                command=create(null);
                for(const k of keys(s)) if(k!=="bind") command[k]=s[k];
                bind=s.bind;
            }
            object(command);
            const schema=has(catalog,command.op)?catalog[command.op]:null;
            if(!schema) fail("invalid_script","Unknown operation.");
            only(command,keys(schema.properties));
            for(const k of schema.required) if(!has(command,k)) fail("invalid_script","Missing field: "+k);
            const wire={command};
            if(has(s,"bind")) {
                if(typeof bind!=="string") fail("invalid_script","bind must be a string.");
                wire.bind=bind;
            }
            return wire;
        }
        const builder=create(null), ops=create(null);
        builder.run=function(steps,opts) {
            opts=options(opts);
            if(has(opts,"bind")) fail("invalid_script","bind belongs to a step.");
            if(!array(steps)) fail("invalid_script","Expected steps array.");
            // Validate the original list, including sparse arrays and extra properties.
            steps=parse(encode(steps,1048576));
            return call("run_script",{steps:steps.map(step)},opts.tolerate===true);
        };
        for(const op of keys(catalog)) {
            ops[op]=function(args,opts) {
                opts=options(opts); object(args);
                args=parse(encode(args,1048576));
                if(has(args,"op") || has(args,"command")) fail("invalid_script","Wrapper arguments cannot contain op or command.");
                const flat={...args,op};
                if(has(opts,"bind")) {
                    if(has(args,"bind")) fail("invalid_script","Duplicate bind.");
                    flat.bind=opts.bind;
                }
                return builder.run([flat],{tolerate:opts.tolerate===true});
            };
        }
        for(const op of ensures) ops[op]=function(args,opts) {
            opts=options(opts); only(args,["video"]);
            if(has(opts,"bind")) fail("invalid_script","Ensures cannot bind.");
            return call(op,args,opts.tolerate===true);
        };
        builder.ops=freeze(ops);
        builder.query=q=>call("query",{query:q},false);
        builder.summary=function(page) { return call("get_document_summary",page===undefined?{offset:0,limit:50}:page,false); };
        builder.report_scenes=report=>call("report_scenes",report,false);
        for(const key of ["selection","playhead","focusedTrack","tracks"])
            define(builder,key,{enumerable:true,get:()=>builder.summary()[key==="tracks"?"trackLabels":key]});
        function deepFreeze(value) {
            if(value && typeof value==="object") { for(const k of keys(value)) deepFreeze(value[k]); freeze(value); }
            return value;
        }
        const params=new Proxy(deepFreeze(values),{
            get(target,key) {
                if(typeof key!=="string" || !has(target,key)) fail("invalid_script","Undeclared parameter: "+String(key));
                return target[key];
            },
            set(){ fail("invalid_script","Parameters are immutable."); },
            defineProperty(){ fail("invalid_script","Parameters are immutable."); },
            deleteProperty(){ fail("invalid_script","Parameters are immutable."); }
        });
        let logged=0;
        const console=create(null);
        for(const level of ["log","warn","error"]) console[level]=function(...args) {
            const text=encode(args,65536);
            logged+=bytes(text); if(logged>65536) limit("Console exceeds 64 KiB.");
            call("__console",{level,text},false);
        };
        // Capture the native bridge in this closure; user code cannot call it directly.
        delete globalThis.__clipbuilderHost;
        define(globalThis,"builder",{value:freeze(builder)});
        define(globalThis,"params",{value:params});
        define(globalThis,"script",{value:deepFreeze(metadata)});
        define(globalThis,"console",{value:freeze(console)});
        define(globalThis,"__clipbuilderReturn",{value:v=>encode(v,65536)});
        // Prevent prototype hooks from changing the trusted serializer after setup.
        freeze(Object.prototype); freeze(Array.prototype);
        })(__clipbuilderHost, \(catalog), \(paramsJSON), \(metadata), \(ensureJSON));
        """
    }

    static func response(_ data: Data) throws -> Data {
        let decoder = JSONDecoder()
        let value: ScriptValue
        if let result = try? decoder.decode(BuilderScriptResult.self, from: data) {
            value = .object([
                "outcomes": .array(result.outcomes.map(project)),
                "completed": .bool(result.completed),
                "hasDocumentChanges": .bool(result.hasDocumentChanges)
            ])
        } else if let outcome = try? decoder.decode(CommandOutcome.self, from: data),
                  case .refused(let code, let reason) = outcome {
            return try JSONEncoder().encode(ScriptValue.object(["error": .object(["code": .string(code), "reason": .string(reason)])]))
        } else { value = try decoder.decode(ScriptValue.self, from: data) }
        return try JSONEncoder().encode(ScriptValue.object(["value": value]))
    }

    static func project(_ outcome: CommandOutcome) -> ScriptValue {
        switch outcome {
        case .applied(let actual, let ids, let warnings):
            .object(["status": .string("applied"), "actualValues": actual,
                     "createdIDs": .object(ids.mapValues(ScriptValue.string)), "warnings": .array(warnings.map(ScriptValue.string))])
        case .unchanged(let reason): .object(["status": .string("unchanged"), "reason": .string(reason)])
        case .refused(let code, let reason): .object(["status": .string("refused"), "code": .string(code == "invalid_command" ? "invalid_script" : code), "reason": .string(reason)])
        }
    }

    static func error(_ code: String, _ reason: String) -> Data {
        (try? JSONEncoder().encode(ScriptValue.object(["error": .object(["code": .string(code), "reason": .string(reason)])]))) ?? Data()
    }
}
