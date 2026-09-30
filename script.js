document.querySelector('.menu')?.addEventListener('click',()=>document.querySelector('.top').classList.toggle('open'));
const form=document.querySelector('#project-form');
if(form){
  const params=new URLSearchParams(location.search);
  if(params.get('type')==='lead')document.querySelector('#project-type').value='Lead Inspection';
  form.addEventListener('submit',async e=>{
    e.preventDefault();
    const button=form.querySelector('button[type="submit"]');
    const status=document.querySelector('#form-status');
    const original=button.textContent;
    button.disabled=true;
    button.textContent='Sending...';
    status.textContent='Sending your request securely...';
    try{
      const data=new FormData(form);
      const customer=(data.get('name')||'New Customer').toString().trim();
      const project=(data.get('type')||'Project Request').toString().trim();
      data.set('_subject',`LA CORE ESTIMATE — ${customer} — ${project}`);
      const response=await fetch(form.action,{method:'POST',body:data,headers:{Accept:'application/json'}});
      if(!response.ok)throw new Error('Submission failed');
      form.reset();
      status.textContent='Thank you! Your request has been sent to LA Core. We’ll be in touch soon.';
      button.textContent='Request Sent';
    }catch(error){
      status.textContent='We couldn’t send your request. Please call 202-699-8023 or email lacoredgroupllc@gmail.com.';
      button.textContent=original;
      button.disabled=false;
    }
  });
}
const inspectionForm=document.querySelector('#inspection-form');
if(inspectionForm){
 const params=new URLSearchParams(location.search);
 const requested=params.get('inspection');
 const inspectionType=document.querySelector('#inspection-type');
 if(requested && [...inspectionType.options].some(option=>option.value===requested))inspectionType.value=requested;
 inspectionForm.addEventListener('submit',async e=>{
  e.preventDefault();
  const button=inspectionForm.querySelector('button[type="submit"]');
  const status=document.querySelector('#inspection-form-status');
  button.disabled=true;button.textContent='Sending...';status.textContent='Sending your inspection request...';
  try{
   const data=new FormData(inspectionForm);
   const name=String(data.get('name')||'New Customer').trim();
   const type=String(data.get('inspection_type')||'Inspection').trim();
   data.set('_subject',`LA CORE LEAD INSPECTION — ${name} — ${type}`);
   const response=await fetch(inspectionForm.action,{method:'POST',body:data,headers:{Accept:'application/json'}});
   if(!response.ok)throw new Error('Submission failed');
   inspectionForm.reset();status.textContent='Thank you! Your inspection request has been sent to LA Core. We will contact you to discuss the next steps. This is not a confirmed appointment.';button.textContent='Request Sent';
  }catch(error){status.textContent='We could not send your request. Please call 202-699-8023 or email lacoredgroupllc@gmail.com.';button.textContent='Send Inspection Request';button.disabled=false;}
 });
}
