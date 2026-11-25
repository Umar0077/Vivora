const {before, after, test} = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const {initializeTestEnvironment, assertFails, assertSucceeds} = require('@firebase/rules-unit-testing');
const {doc, collection, getDoc, getDocs, setDoc, deleteDoc, updateDoc, getCountFromServer} = require('firebase/firestore');
let env;
before(async () => {
  env = await initializeTestEnvironment({projectId:'demo-pdt-admin', firestore:{host:'127.0.0.1',port:8088,rules:fs.readFileSync(path.resolve(__dirname,'../../firestore.rules'),'utf8')}});
  await env.withSecurityRulesDisabled(async ctx => {
    const db = ctx.firestore();
    const seed = {
      'admin/admin1':{role:'admin',isActive:true,email:'admin@example.test'},
      'admin/inactive':{role:'admin',isActive:false},
      'admin/wrongrole':{role:'student',isActive:true},
      'admin/legacy':{role:'admin',isActive:true,password:'synthetic-test-only'},
      'users/student1':{fullName:'Sample One'}, 'users/student2':{fullName:'Sample Two'},
      'users/student1/dailyLogs/2026-11-25':{overallScore:75},
      'users/student1/activityLogs/2026_11_25':{appUsageMinutes:20},
      'users/student1/activityLogs/2026_11_25/appUsage/sample':{usageMinutes:20},
      'users/student1/focusSessions/session':{focusedSeconds:60},
      'users/student1/insights/day':{engine:'behavior_analysis_v2'},
      'users/student1/settings/activityTracking':{enabled:false},
      'users/student1/settings/appCategories':{},
      'users/student1/aiState/advice':{}, 'users/student1/aiState/studyPlan':{},
      'users/student1/aiSummaries/weekly_day':{}, 'users/student1/aiRecommendations/rec':{},
      'users/student1/aiChat/private':{text:'Private synthetic conversation'},
      'users/student1/settings/private':{}, 'users/student1/unknown/private':{},
    };
    for(const [p,data] of Object.entries(seed)) await setDoc(doc(db,p),data);
  });
});
after(async () => {await env?.cleanup();});
const db = uid => uid ? env.authenticatedContext(uid).firestore() : env.unauthenticatedContext().firestore();
for(const uid of [null,'student2','inactive','wrongrole','legacy']) {
  test(`${uid ?? 'anonymous'} cannot read another user or enumerate users`, async()=>{
    await assertFails(getDoc(doc(db(uid),'users/student1')));
    await assertFails(getDocs(collection(db(uid),'users')));
  });
}
test('owner retains profile and private-chat access', async()=>{
  await assertSucceeds(getDoc(doc(db('student1'),'users/student1')));
  await assertSucceeds(getDoc(doc(db('student1'),'users/student1/aiChat/private')));
  await assertSucceeds(setDoc(doc(db('student1'),'users/student1/dailyLogs/owner-test'),{overallScore:50}));
});
test('active admin can list users and count profiles', async()=>{
  await assertSucceeds(getDocs(collection(db('admin1'),'users')));
  await assertSucceeds(getCountFromServer(collection(db('admin1'),'users')));
});
for(const p of ['dailyLogs/2026-11-25','activityLogs/2026_11_25','activityLogs/2026_11_25/appUsage/sample','focusSessions/session','insights/day','settings/activityTracking','settings/appCategories','aiState/advice','aiState/studyPlan','aiSummaries/weekly_day','aiRecommendations/rec']) {
  test(`admin can read ${p}`,async()=>{await assertSucceeds(getDoc(doc(db('admin1'),`users/student1/${p}`)));});
}
for(const p of ['aiChat/private','settings/private','unknown/private']) {
  test(`admin cannot read ${p}`,async()=>{await assertFails(getDoc(doc(db('admin1'),`users/student1/${p}`)));});
}
test('admin cannot enumerate private chat',async()=>{await assertFails(getDocs(collection(db('admin1'),'users/student1/aiChat')));});
for(const uid of ['student1','admin1',null]) {
  test(`${uid ?? 'anonymous'} cannot grant or modify admin membership`,async()=>{
    await assertFails(setDoc(doc(db(uid),'admin/new-admin'),{role:'admin',isActive:true}));
    await assertFails(updateDoc(doc(db(uid),'admin/admin1'),{isActive:false}));
    await assertFails(deleteDoc(doc(db(uid),'admin/admin1')));
    await assertFails(getDocs(collection(db(uid),'admin')));
  });
}
test('admin has no cross-user write/delete privileges',async()=>{
  await assertFails(setDoc(doc(db('admin1'),'users/student1'),{fullName:'Changed'}));
  await assertFails(deleteDoc(doc(db('admin1'),'users/student1/dailyLogs/2026-11-25')));
});
test('admin may read only its own clean membership document',async()=>{
  await assertSucceeds(getDoc(doc(db('admin1'),'admin/admin1')));
  await assertFails(getDoc(doc(db('student2'),'admin/admin1')));
  await assertFails(getDoc(doc(db('legacy'),'admin/legacy')));
});
test('server revocation immediately removes reads',async()=>{
  await env.withSecurityRulesDisabled(ctx=>setDoc(doc(ctx.firestore(),'admin/revoked'),{role:'admin',isActive:true}));
  await assertSucceeds(getDoc(doc(db('revoked'),'users/student1')));
  await env.withSecurityRulesDisabled(ctx=>updateDoc(doc(ctx.firestore(),'admin/revoked'),{isActive:false}));
  await assertFails(getDoc(doc(db('revoked'),'users/student1')));
});
